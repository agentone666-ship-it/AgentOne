import { Type } from "@earendil-works/pi-ai";
import type { AgentTool } from "@earendil-works/pi-agent-core";
import type {
  MemorySnippet,
  RuntimeAction,
  SafeToolName,
  SanitizedContext,
  WakeBudget,
} from "./protocol.js";

export interface WakeToolState {
  context: SanitizedContext;
  memory: MemorySnippet[];
  budget: WakeBudget;
  actions: RuntimeAction[];
  consumedEnergy: number;
}

type SafeAgentTool = AgentTool<any, Record<string, unknown>> & { name: SafeToolName };

export function createSafeTools(state: WakeToolState): SafeAgentTool[] {
  const textResult = (value: unknown, details: Record<string, unknown> = {}) => ({
    content: [{ type: "text" as const, text: JSON.stringify(value) }],
    details,
  });
  const recordAction = (action: RuntimeAction) => {
    state.actions.push(action);
    return textResult({ accepted: true }, { actionType: action.type });
  };

  return [
    {
      name: "get_current_context",
      label: "Read current sanitized context",
      description: "Returns only context already sanitized by AgentOne's Swift privacy firewall.",
      parameters: Type.Object({}),
      execute: async () => textResult(state.context, { source: "swift_privacy_firewall" }),
    },
    {
      name: "search_memory",
      label: "Search recent memory",
      description: "Searches the bounded memory snippets supplied for this wake session.",
      parameters: Type.Object({ query: Type.String({ minLength: 1, maxLength: 200 }) }),
      execute: async (_id, raw) => {
        const { query } = raw as { query: string };
        const terms = tokenize(query);
        const matches = state.memory
          .map((item) => ({ item, score: overlap(terms, tokenize(`${item.summary} ${item.tags.join(" ")}`)) }))
          .filter(({ score }) => score > 0)
          .sort((left, right) => right.score - left.score)
          .slice(0, 8)
          .map(({ item }) => item);
        return textResult(matches, { resultCount: matches.length });
      },
    },
    {
      name: "read_recent_diary",
      label: "Read recent diary",
      description: "Returns the bounded, structured diary excerpts supplied by Swift.",
      parameters: Type.Object({ limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 20 })) }),
      execute: async (_id, raw) => {
        const { limit } = raw as { limit?: number };
        const count = limit ?? 8;
        return textResult(state.memory.slice(-count), { resultCount: Math.min(count, state.memory.length) });
      },
    },
    {
      name: "append_inner_journal",
      label: "Append inner journal",
      description: "Proposes a synthesized Agent reflection for Swift to append to the immutable Agent diary.",
      parameters: Type.Object({
        observation: Type.String({ minLength: 1, maxLength: 800 }),
        hypothesis: Type.Optional(Type.String({ maxLength: 800 })),
        uncertainty: Type.Number({ minimum: 0, maximum: 1 }),
        disposition: Type.Union([
          Type.Literal("spoken"),
          Type.Literal("heldBack"),
          Type.Literal("postponedForSurprise"),
          Type.Literal("observationOnly"),
        ]),
      }),
      executionMode: "sequential",
      execute: async (_id, raw) => recordAction({
        type: "inner_journal",
        payload: raw as Record<string, unknown>,
      }),
    },
    {
      name: "update_working_intention",
      label: "Update working intention",
      description: "Proposes a working-intention update; Swift remains the authority that accepts and records it.",
      parameters: Type.Object({ title: Type.String({ minLength: 1, maxLength: 240 }), summary: Type.Optional(Type.String({ maxLength: 800 })) }),
      executionMode: "sequential",
      execute: async (_id, raw) => recordAction({ type: "working_intention", payload: raw as Record<string, unknown> }),
    },
    ...classificationTools(recordAction),
    {
      name: "show_curiosity_prompt",
      label: "Show a curiosity prompt",
      description: "Asks a neutral, low-pressure question through the floating life form.",
      parameters: Type.Object({ text: Type.String({ minLength: 1, maxLength: 280 }) }),
      executionMode: "sequential",
      execute: async (_id, raw) => recordAction({ type: "curiosity_prompt", payload: raw as Record<string, unknown> }),
    },
    {
      name: "show_return_card",
      label: "Show return card",
      description: "Proposes a return-to-task card. It cannot restore or manipulate other apps directly.",
      parameters: Type.Object({ taskTitle: Type.String({ minLength: 1, maxLength: 240 }), note: Type.Optional(Type.String({ maxLength: 500 })) }),
      executionMode: "sequential",
      execute: async (_id, raw) => recordAction({ type: "return_card", payload: raw as Record<string, unknown> }),
    },
    {
      name: "save_detour_for_later",
      label: "Save a detour",
      description: "Proposes saving the current detour as a later-readable note.",
      parameters: Type.Object({ title: Type.String({ minLength: 1, maxLength: 240 }), summary: Type.String({ minLength: 1, maxLength: 800 }) }),
      executionMode: "sequential",
      execute: async (_id, raw) => recordAction({ type: "saved_detour", payload: raw as Record<string, unknown> }),
    },
    {
      name: "propose_surprise",
      label: "Propose a surprise",
      description: "Records a reversible digital surprise proposal. It never purchases, sends, publishes, or executes it.",
      parameters: Type.Object({ idea: Type.String({ minLength: 1, maxLength: 800 }), risk: Type.Union([Type.Literal("low"), Type.Literal("medium")]) }),
      executionMode: "sequential",
      execute: async (_id, raw) => {
        const params = raw as { idea: string; risk: "low" | "medium" };
        const allowed = state.budget.surpriseRisk === "medium" || (state.budget.surpriseRisk === "low" && params.risk === "low");
        if (!allowed) throw new Error("Surprise risk exceeds this wake session's budget");
        return recordAction({ type: "surprise_proposal", payload: params });
      },
    },
    {
      name: "consume_energy_budget",
      label: "Consume energy budget",
      description: "Accounts for proactive Agent energy within this wake session.",
      parameters: Type.Object({ units: Type.Integer({ minimum: 1, maximum: 100 }), reason: Type.String({ minLength: 1, maxLength: 240 }) }),
      executionMode: "sequential",
      execute: async (_id, raw) => {
        const params = raw as { units: number; reason: string };
        state.consumedEnergy += params.units;
        return recordAction({ type: "energy_consumed", payload: { ...params, total: state.consumedEnergy } });
      },
    },
  ];
}

function classificationTools(
  recordAction: (action: RuntimeAction) => { content: { type: "text"; text: string }[]; details: Record<string, unknown> },
): SafeAgentTool[] {
  const parameters = Type.Object({ eventID: Type.Optional(Type.String()), confidence: Type.Number({ minimum: 0, maximum: 1 }), reason: Type.String({ maxLength: 500 }) });
  return [
    {
      name: "mark_context_related",
      label: "Mark context related",
      description: "Proposes that a context is related to the active intention.",
      parameters,
      executionMode: "sequential",
      execute: async (_id, raw) => recordAction({ type: "context_classification", payload: { classification: "related", ...(raw as Record<string, unknown>) } }),
    },
    {
      name: "mark_context_distracting",
      label: "Mark context distracting",
      description: "Proposes that a context conflicts with the active intention.",
      parameters,
      executionMode: "sequential",
      execute: async (_id, raw) => recordAction({ type: "context_classification", payload: { classification: "distracting", ...(raw as Record<string, unknown>) } }),
    },
  ];
}

function tokenize(value: string): Set<string> {
  return new Set(value.toLocaleLowerCase().split(/[^\p{L}\p{N}]+/u).filter((term) => term.length > 1));
}

function overlap(left: Set<string>, right: Set<string>): number {
  let score = 0;
  for (const term of left) if (right.has(term)) score += 1;
  return score;
}
