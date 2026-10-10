import { chatCompletionsEndpoint } from "./completions-url.js";
import { createAssistantMessageEventStream, type AssistantMessage } from "@earendil-works/pi-ai";
import type { StreamFn } from "@earendil-works/pi-agent-core";

/** Preserve Pi's tool loop for gateways that only implement non-streaming completions. */
export const nonStreamingCompletions: StreamFn = (model, context, options) => {
  const stream = createAssistantMessageEventStream();
  const message: AssistantMessage = {
    role: "assistant", api: model.api, provider: model.provider, model: model.id,
    content: [], timestamp: Date.now(), stopReason: "stop",
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
  };
  let httpStatus: number | undefined;
  void (async () => {
    try {
      const messages: Record<string, unknown>[] = [];
      if (context.systemPrompt) messages.push({ role: "system", content: context.systemPrompt });
      for (const item of context.messages) {
        if (item.role === "user") {
          messages.push({ role: "user", content: typeof item.content === "string" ? item.content : item.content.filter(c => c.type === "text").map(c => c.text).join("\n") });
        } else if (item.role === "toolResult") {
          messages.push({ role: "tool", tool_call_id: item.toolCallId, content: item.content.filter(c => c.type === "text").map(c => c.text).join("\n") });
        } else {
          const calls = item.content.filter(c => c.type === "toolCall").map(c => ({ id: c.id, type: "function", function: { name: c.name, arguments: JSON.stringify(c.arguments) } }));
          messages.push({ role: "assistant", content: item.content.filter(c => c.type === "text").map(c => c.text).join("\n") || null,
            ...(calls.length ? { tool_calls: calls } : {}) });
        }
      }
      const response = await fetch(chatCompletionsEndpoint(model.baseUrl), {
        method: "POST", headers: { ...model.headers, "Content-Type": "application/json", Authorization: `Bearer ${options?.apiKey ?? ""}` },
        ...(options?.signal ? { signal: options.signal } : {}),
        body: JSON.stringify({ model: model.id, messages, stream: false, max_tokens: options?.maxTokens ?? model.maxTokens,
          ...(context.tools?.length ? { tools: context.tools.map(tool => ({ type: "function", function: { name: tool.name, description: tool.description, parameters: tool.parameters } })) } : {}) }),
      });
      httpStatus = response.status;
      if (!response.ok) throw new Error(`Model HTTP ${response.status}`);
      const body = await response.json() as {
        choices?: { message?: { content?: string; tool_calls?: { id: string; function: { name: string; arguments: string } }[] }; finish_reason?: string }[];
        usage?: { prompt_tokens?: number; completion_tokens?: number; total_tokens?: number };
      };
      const choice = body.choices?.[0];
      if (!choice?.message) throw new Error("Model response is missing a message");
      if (choice.message.content) message.content.push({ type: "text", text: choice.message.content });
      for (const call of choice.message.tool_calls ?? []) {
        const args: unknown = JSON.parse(call.function.arguments);
        if (!args || typeof args !== "object" || Array.isArray(args)) throw new Error("Invalid tool arguments");
        message.content.push({ type: "toolCall", id: call.id, name: call.function.name, arguments: args as Record<string, unknown> });
      }
      message.usage.input = body.usage?.prompt_tokens ?? 0;
      message.usage.output = body.usage?.completion_tokens ?? 0;
      message.usage.totalTokens = body.usage?.total_tokens ?? message.usage.input + message.usage.output;
      message.stopReason = choice.message.tool_calls?.length ? "toolUse" : choice.finish_reason === "length" ? "length" : "stop";
      stream.push({ type: "done", reason: message.stopReason, message });
    } catch {
      message.stopReason = options?.signal?.aborted ? "aborted" : "error";
      message.errorMessage = httpStatus && httpStatus >= 400 ? `Model HTTP ${httpStatus}` : "Non-streaming model request failed";
      stream.push({ type: "error", reason: message.stopReason, error: message });
    }
  })();
  return stream;
};
