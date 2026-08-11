export const protocolVersion = 1 as const;

export const safeToolNames = [
  "get_current_context",
  "search_memory",
  "read_recent_diary",
  "append_inner_journal",
  "update_working_intention",
  "mark_context_related",
  "mark_context_distracting",
  "show_curiosity_prompt",
  "show_return_card",
  "save_detour_for_later",
  "propose_surprise",
  "consume_energy_budget",
] as const;

export type SafeToolName = (typeof safeToolNames)[number];

export interface SanitizedContext {
  capturedAt: string;
  applicationName?: string;
  bundleIdentifier?: string;
  windowTitle?: string;
  url?: string;
  documentPath?: string;
  contentSummary?: string;
  selectedText?: string;
  submittedText?: string;
  screenText?: string;
  interactionTarget?: string;
  contextTransition?: string;
  semanticTags: string[];
  isSensitive: boolean;
  activeIntent?: {
    id?: string;
    title: string;
    summary?: string;
  };
  driftDurationSeconds?: number;
}

export interface MemorySnippet {
  id: string;
  timestamp: string;
  kind: string;
  summary: string;
  tags: string[];
}

export interface WakeBudget {
  maxTokens: number;
  maxTurns: number;
  maxDurationMs: number;
  allowedTools: SafeToolName[];
  surpriseRisk: "none" | "low" | "medium";
}

export interface WakePayload {
  reason: string;
  sanitizedContext: SanitizedContext;
  recentMemory: MemorySnippet[];
  budget: WakeBudget;
}

export interface ChatMessage {
  role: "user" | "assistant";
  content: string;
}

export interface ChatPayload {
  purpose: "conversation" | "context_enrichment" | "daily_digest";
  messages: ChatMessage[];
  sanitizedContext?: SanitizedContext;
  recentMemory: MemorySnippet[];
  maxTokens: number;
  maxDurationMs: number;
}

export type RuntimeRequest =
  | { version: 1; id: string; type: "health" }
  | { version: 1; id: string; type: "wake"; payload: WakePayload }
  | { version: 1; id: string; type: "chat"; payload: ChatPayload }
  | { version: 1; id: string; type: "shutdown" };

export interface RuntimeAction {
  type:
    | "inner_journal"
    | "working_intention"
    | "context_classification"
    | "curiosity_prompt"
    | "return_card"
    | "saved_detour"
    | "surprise_proposal"
    | "energy_consumed";
  payload: Record<string, unknown>;
}

export interface RuntimeUsage {
  turns: number;
  inputTokens: number;
  outputTokens: number;
  totalTokens: number;
  toolCalls: number;
  durationMs: number;
  stoppedByBudget: boolean;
}

export interface RuntimeModelExecution {
  route: "offline" | "cloud";
  provider: string;
  model: string;
}

export type RuntimeResponse =
  | {
      version: 1;
      id: string;
      type: "ready";
      payload: {
        runtime: "pi-agent-core";
        runtimeMode: "offline-faux" | "cloud";
        provider: string;
        model: string;
        piVersion: string;
        protocolVersion: 1;
        safeTools: readonly SafeToolName[];
      };
    }
  | {
      version: 1;
      id: string;
      type: "event";
      payload: Record<string, unknown>;
    }
  | {
      version: 1;
      id: string;
      type: "result";
      payload: {
        outcome: string;
        spokenText?: string;
        actions: RuntimeAction[];
        usage: RuntimeUsage;
        model: RuntimeModelExecution;
      };
    }
  | {
      version: 1;
      id: string;
      type: "error";
      payload: { code: string; message: string; retryable?: boolean };
    };

export function defaultBudget(): WakeBudget {
  return {
    maxTokens: 2_400,
    maxTurns: 3,
    maxDurationMs: 8_000,
    allowedTools: [
      "get_current_context",
      "search_memory",
      "read_recent_diary",
      "append_inner_journal",
      "show_curiosity_prompt",
      "show_return_card",
      "consume_energy_budget",
    ],
    surpriseRisk: "none",
  };
}

export function normalizeBudget(value: WakeBudget): WakeBudget {
  const allowed = new Set<SafeToolName>(safeToolNames);
  return {
    maxTokens: clampInteger(value.maxTokens, 128, 16_000),
    maxTurns: clampInteger(value.maxTurns, 1, 12),
    maxDurationMs: clampInteger(value.maxDurationMs, 500, 60_000),
    allowedTools: [...new Set(value.allowedTools.filter((name) => allowed.has(name)))],
    surpriseRisk: ["none", "low", "medium"].includes(value.surpriseRisk)
      ? value.surpriseRisk
      : "none",
  };
}

function clampInteger(value: number, minimum: number, maximum: number): number {
  if (!Number.isFinite(value)) return minimum;
  return Math.min(Math.max(Math.trunc(value), minimum), maximum);
}

export function parseRequest(line: string): RuntimeRequest {
  const raw: unknown = JSON.parse(line);
  if (!isRecord(raw)) throw new Error("Request must be a JSON object");
  if (raw.version !== protocolVersion) throw new Error("Unsupported protocol version");
  if (typeof raw.id !== "string" || raw.id.length < 1) throw new Error("Request id is required");

  if (raw.type === "health" || raw.type === "shutdown") {
    return { version: 1, id: raw.id, type: raw.type };
  }
  if ((raw.type !== "wake" && raw.type !== "chat") || !isRecord(raw.payload)) {
    throw new Error("Unsupported request type");
  }

  if (raw.type === "chat") {
    return {
      version: 1,
      id: raw.id,
      type: "chat",
      payload: parseChatPayload(raw.payload),
    };
  }

  return {
    version: 1,
    id: raw.id,
    type: "wake",
    payload: parseWakePayload(raw.payload),
  };
}

function parseChatPayload(raw: Record<string, unknown>): ChatPayload {
  if (!Array.isArray(raw.messages)) throw new Error("Chat request is missing messages");
  const messages = raw.messages.flatMap((item): ChatMessage[] => {
    if (!isRecord(item)) return [];
    if ((item.role !== "user" && item.role !== "assistant") || typeof item.content !== "string") return [];
    const content = item.content.trim().slice(0, 8_000);
    return content ? [{ role: item.role, content }] : [];
  }).slice(-20);
  if (messages.length < 1 || messages[messages.length - 1]?.role !== "user") {
    throw new Error("Chat must end with a user message");
  }

  const context = isRecord(raw.sanitizedContext)
    ? parseSanitizedContext(raw.sanitizedContext)
    : undefined;
  const purpose = raw.purpose === "context_enrichment"
    ? "context_enrichment"
    : raw.purpose === "daily_digest"
      ? "daily_digest"
      : "conversation";
  const recentMemory = parseRecentMemory(raw.recentMemory)
    .slice(purpose === "daily_digest" ? -64 : -20);
  return {
    purpose,
    messages,
    ...(context ? { sanitizedContext: context } : {}),
    recentMemory,
    maxTokens: clampInteger(numberValue(raw.maxTokens, 2_400), 128, 16_000),
    maxDurationMs: clampInteger(numberValue(raw.maxDurationMs, 30_000), 500, 60_000),
  };
}

function parseWakePayload(raw: Record<string, unknown>): WakePayload {
  if (typeof raw.reason !== "string" || !isRecord(raw.sanitizedContext)) {
    throw new Error("Wake request is missing reason or sanitizedContext");
  }
  const sanitizedContext = parseSanitizedContext(raw.sanitizedContext);
  const recentMemory = parseRecentMemory(raw.recentMemory);

  const budget = isRecord(raw.budget)
    ? normalizeBudget({
        maxTokens: numberValue(raw.budget.maxTokens, 2_400),
        maxTurns: numberValue(raw.budget.maxTurns, 3),
        maxDurationMs: numberValue(raw.budget.maxDurationMs, 8_000),
        allowedTools: stringArray(raw.budget.allowedTools).filter(isSafeToolName),
        surpriseRisk: isSurpriseRisk(raw.budget.surpriseRisk) ? raw.budget.surpriseRisk : "none",
      })
    : defaultBudget();

  return { reason: raw.reason, sanitizedContext, recentMemory, budget };
}

function parseSanitizedContext(context: Record<string, unknown>): SanitizedContext {
  if (typeof context.capturedAt !== "string" || typeof context.isSensitive !== "boolean") {
    throw new Error("Invalid sanitizedContext");
  }

  const activeIntent = isRecord(context.activeIntent) && typeof context.activeIntent.title === "string"
    ? {
        ...(typeof context.activeIntent.id === "string" ? { id: context.activeIntent.id } : {}),
        title: context.activeIntent.title,
        ...(typeof context.activeIntent.summary === "string" ? { summary: context.activeIntent.summary } : {}),
      }
    : undefined;

  return {
    capturedAt: context.capturedAt,
    semanticTags: stringArray(context.semanticTags),
    isSensitive: context.isSensitive,
    ...optionalString(context, "applicationName"),
    ...optionalString(context, "bundleIdentifier"),
    ...optionalString(context, "windowTitle"),
    ...optionalString(context, "url"),
    ...optionalString(context, "documentPath"),
    ...optionalString(context, "contentSummary"),
    ...optionalString(context, "selectedText"),
    ...optionalString(context, "submittedText"),
    ...optionalString(context, "screenText"),
    ...optionalString(context, "interactionTarget"),
    ...optionalString(context, "contextTransition"),
    ...(activeIntent ? { activeIntent } : {}),
    ...(typeof context.driftDurationSeconds === "number"
      ? { driftDurationSeconds: Math.max(0, context.driftDurationSeconds) }
      : {}),
  };
}

function parseRecentMemory(value: unknown): MemorySnippet[] {
  return Array.isArray(value)
    ? value.flatMap((item): MemorySnippet[] => {
        if (!isRecord(item)) return [];
        if (
          typeof item.id !== "string" ||
          typeof item.timestamp !== "string" ||
          typeof item.kind !== "string" ||
          typeof item.summary !== "string"
        ) return [];
        return [{
          id: item.id,
          timestamp: item.timestamp,
          kind: item.kind,
          summary: item.summary.slice(0, 600),
          tags: stringArray(item.tags).slice(0, 16),
        }];
      })
    : [];
}

function optionalString(record: Record<string, unknown>, key: string): Record<string, string> {
  return typeof record[key] === "string" ? { [key]: record[key] } : {};
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];
}

function numberValue(value: unknown, fallback: number): number {
  return typeof value === "number" ? value : fallback;
}

function isSurpriseRisk(value: unknown): value is WakeBudget["surpriseRisk"] {
  return value === "none" || value === "low" || value === "medium";
}

function isSafeToolName(value: string): value is SafeToolName {
  return (safeToolNames as readonly string[]).includes(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
