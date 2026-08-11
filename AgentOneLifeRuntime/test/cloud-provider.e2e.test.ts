import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { once } from "node:events";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { createInterface, type Interface } from "node:readline";
import test from "node:test";
import { fileURLToPath } from "node:url";

type WireResponse = {
  version: number;
  id: string;
  type: "ready" | "event" | "result" | "error";
  payload: unknown;
};

type CapturedRequest = {
  method: string | undefined;
  url: string | undefined;
  authorization: string | undefined;
  apiKey: string | undefined;
  anthropicVersion: string | undefined;
  userAgent: string | undefined;
  kimiHeaders: Record<string, string | undefined>;
  accept: string | undefined;
  body: Record<string, unknown>;
};

type MockMode = "success" | "unauthorized" | "server-error";

class OpenAIResponsesMock {
  readonly requests: CapturedRequest[] = [];
  private readonly server: Server;
  private mode: MockMode = "success";
  private successTurn = 0;
  private baseUrlValue = "";

  constructor() {
    this.server = createServer((request, response) => {
      void this.handle(request, response);
    });
  }

  get baseUrl(): string {
    assert.ok(this.baseUrlValue);
    return `${this.baseUrlValue}/algo`;
  }

  get kimiBaseUrl(): string {
    assert.ok(this.baseUrlValue);
    return `${this.baseUrlValue}/coding`;
  }

  setMode(mode: MockMode): void {
    this.mode = mode;
    this.successTurn = 0;
  }

  async start(): Promise<void> {
    this.server.listen(0, "127.0.0.1");
    await once(this.server, "listening");
    const address = this.server.address() as AddressInfo;
    this.baseUrlValue = `http://127.0.0.1:${address.port}`;
  }

  async stop(): Promise<void> {
    this.server.close();
    await once(this.server, "close");
  }

  private async handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const chunks: Buffer[] = [];
    for await (const chunk of request) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    const text = Buffer.concat(chunks).toString("utf8");
    const body = text ? JSON.parse(text) as Record<string, unknown> : {};
    this.requests.push({
      method: request.method,
      url: request.url,
      authorization: request.headers.authorization,
      apiKey: headerValue(request, "x-api-key"),
      anthropicVersion: headerValue(request, "anthropic-version"),
      userAgent: headerValue(request, "user-agent"),
      kimiHeaders: {
        "X-Msh-Platform": headerValue(request, "x-msh-platform"),
        "X-Msh-Version": headerValue(request, "x-msh-version"),
        "X-Msh-Device-Name": headerValue(request, "x-msh-device-name"),
        "X-Msh-Device-Model": headerValue(request, "x-msh-device-model"),
        "X-Msh-Os-Version": headerValue(request, "x-msh-os-version"),
        "X-Msh-Device-Id": headerValue(request, "x-msh-device-id"),
      },
      accept: headerValue(request, "accept"),
      body,
    });

    if (this.mode === "unauthorized") {
      this.sendError(response, 401, "raw-401-provider-secret sk-test-agentone-cloud");
      return;
    }
    if (this.mode === "server-error") {
      this.sendError(response, 500, "raw-500-upstream-database-detail");
      return;
    }

    this.successTurn += 1;
    const isChatCompletions = request.url?.endsWith("/chat/completions") === true;
    const isAnthropicMessages = request.url?.endsWith("/v1/messages") === true;
    const tools = Array.isArray(body.tools) ? body.tools : [];
    if (isAnthropicMessages) {
      const isContextEnrichment = JSON.stringify(body.system ?? "").includes("activity_title");
      const isDailyDigest = JSON.stringify(body.system ?? "").includes("unfinished_thread");
      const events = tools.length > 0 && this.successTurn === 1
        ? anthropicToolCallEvents()
        : anthropicTextEvents(isContextEnrichment
          ? JSON.stringify({
            activity_title: "提交 AgentOne Context 识别问题",
            summary: "用户指出截图已生成，但本次回车提交的具体原文仍未被可靠识别。",
            observation: "提交原文和整窗 OCR 需要分开保存。",
            hypothesis: null,
            considered_action: null,
            why: "这是一条应进入当天日记的具体反馈。",
            tags: ["AgentOne", "Context", "OCR"],
            evidence_title: "回车关键截图",
            evidence_summary: "截图 OCR 包含本次提交原文。",
            disposition: "observationOnly",
            uncertainty: 0.05,
          })
          : isDailyDigest
            ? JSON.stringify({
              headline: "把 AgentOne 从记录器变成会回想的生命",
              overview: "今天围绕 Context 日记、主动陪伴和 LUMA 的个性继续推进。零散信号被要求提炼成主线，而不是继续堆成软件流水。",
              highlights: [
                "明确日记必须总结一天具体做过什么",
                "要求 LUMA 在合适时机主动出现",
                "要求内心能联想到长期记忆并保留个性",
              ],
              rhythm: "先发现记录链的缺口，再把问题推进到总结、主动性和关系感三个层面。",
              unfinished_thread: "继续验证真实桌面触发是否足够自然。",
              agent_note: "我记住了你不想要一个只会报表的记录器；今天这次追问，本身就是你一直在守的产品方向。",
              invitation: "我把今天三条散线拧成一根了，要不要一起看两分钟？",
              mood: "thoughtful",
            })
            : undefined);
      response.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive",
      });
      for (const event of events) {
        response.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
      }
      response.end();
      return;
    }
    const events = isChatCompletions
      ? (tools.length > 0 && this.successTurn === 1 ? chatToolCallEvents() : chatTextEvents())
      : (tools.length > 0 && this.successTurn === 1 ? toolCallEvents() : textEvents());
    response.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      connection: "keep-alive",
    });
    for (const event of events) response.write(`data: ${JSON.stringify(event)}\n\n`);
    response.end("data: [DONE]\n\n");
  }

  private sendError(response: ServerResponse, status: number, message: string): void {
    response.writeHead(status, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: { message, type: "mock_provider_error" } }));
  }
}

class CloudSidecar {
  private readonly child: ChildProcessWithoutNullStreams;
  private readonly lines: Interface;
  private stderr = "";
  private stdout = "";

  constructor(environmentOverrides: Record<string, string>) {
    const entrypoint = fileURLToPath(new URL("../../dist/index.js", import.meta.url));
    const environment = { ...process.env };
    for (const key of [
      "AGENTONE_MODEL_ROUTE",
      "AGENTONE_MODEL_PROVIDER",
      "AGENTONE_MODEL_ID",
      "AGENTONE_OPENAI_BASE_URL",
      "AGENTONE_KIMI_BASE_URL",
      "AGENTONE_KIMI_ACCESS_TOKEN",
      "AGENTONE_KIMI_PLATFORM",
      "AGENTONE_KIMI_VERSION",
      "AGENTONE_KIMI_DEVICE_NAME",
      "AGENTONE_KIMI_DEVICE_MODEL",
      "AGENTONE_KIMI_OS_VERSION",
      "AGENTONE_KIMI_DEVICE_ID",
      "OPENAI_API_KEY",
    ]) delete environment[key];
    Object.assign(environment, environmentOverrides);
    this.child = spawn(process.execPath, [entrypoint], {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...environment, NODE_ENV: "test" },
    });
    this.lines = createInterface({ input: this.child.stdout, crlfDelay: Infinity });
    this.lines.on("line", (line) => { this.stdout += `${line}\n`; });
    this.child.stderr.setEncoding("utf8");
    this.child.stderr.on("data", (chunk: string) => { this.stderr += chunk; });
  }

  request(message: Record<string, unknown>, timeoutMs = 20_000): Promise<WireResponse[]> {
    const id = message.id;
    assert.equal(typeof id, "string");
    const responses: WireResponse[] = [];
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        cleanup();
        reject(new Error(`Timed out waiting for cloud sidecar id=${id}; stderr=${this.stderr}`));
      }, timeoutMs);
      const onLine = (line: string) => {
        const response = JSON.parse(line) as WireResponse;
        if (response.id !== id) return;
        responses.push(response);
        if (response.type === "ready" || response.type === "result" || response.type === "error") {
          cleanup();
          resolve(responses);
        }
      };
      const cleanup = () => {
        clearTimeout(timeout);
        this.lines.off("line", onLine);
      };
      this.lines.on("line", onLine);
      this.child.stdin.write(`${JSON.stringify(message)}\n`);
    });
  }

  async shutdown(): Promise<void> {
    const response = terminal(await this.request({ version: 1, id: "cloud-shutdown", type: "shutdown" }));
    assert.equal(response.type, "result");
    const [code, signal] = await once(this.child, "exit") as [number | null, NodeJS.Signals | null];
    assert.equal(code, 0);
    assert.equal(signal, null);
    assert.equal(this.stderr, "");
    this.lines.close();
  }

  assertSecretAbsent(secret: string): void {
    assert.equal(this.stdout.includes(secret), false, "Cloud sidecar leaked a credential to stdout");
    assert.equal(this.stderr.includes(secret), false, "Cloud sidecar leaked a credential to stderr");
  }

  async dispose(): Promise<void> {
    this.lines.close();
    if (this.child.exitCode === null && this.child.signalCode === null) {
      this.child.kill("SIGTERM");
      await once(this.child, "exit");
    }
  }
}

function headerValue(request: IncomingMessage, name: string): string | undefined {
  const value = request.headers[name];
  return Array.isArray(value) ? value[0] : value;
}

function wakeRequest(id: string, overrides: {
  context?: Record<string, unknown>;
  memory?: Record<string, unknown>[];
} = {}): Record<string, unknown> {
  return {
    version: 1,
    id,
    type: "wake",
    payload: {
      reason: "drift_detected",
      sanitizedContext: {
        capturedAt: "2026-07-22T03:00:00.000Z",
        applicationName: "Safari",
        windowTitle: "Paper: Attention and Executive Function",
        contentSummary: "Reading a paper while drafting the introduction.",
        semanticTags: ["paper", "research"],
        isSensitive: false,
        activeIntent: { id: "intent-cloud", title: "完成论文引言" },
        driftDurationSeconds: 72,
        ...overrides.context,
      },
      recentMemory: overrides.memory ?? [{
        id: "memory-cloud",
        timestamp: "2026-07-22T02:58:00.000Z",
        kind: "activity",
        summary: "正在整理执行功能相关论文笔记",
        tags: ["论文", "执行功能"],
      }],
      budget: {
        maxTokens: 1_200,
        maxTurns: 3,
        maxDurationMs: 8_000,
        allowedTools: ["show_return_card"],
        surpriseRisk: "none",
      },
    },
  };
}

function chatRequest(id: string, overrides: {
  purpose?: "conversation" | "context_enrichment" | "daily_digest";
  messages?: Array<{ role: "user" | "assistant"; content: string }>;
  includeContext?: boolean;
  context?: Record<string, unknown>;
  memory?: Array<Record<string, unknown>>;
} = {}): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    purpose: overrides.purpose ?? "conversation",
    messages: overrides.messages ?? [
      { role: "user", content: "刚才我在看什么？" },
      { role: "assistant", content: "你在读一篇注意力相关论文。" },
      { role: "user", content: "帮我接着整理下一步" },
    ],
    recentMemory: overrides.memory ?? [{
      id: "chat-memory-1",
      timestamp: "2026-07-22T09:58:00.000Z",
      kind: "reading_session",
      summary: "用户在整理执行功能论文的论点",
      tags: ["论文", "执行功能"],
    }],
    maxTokens: 900,
    maxDurationMs: 8_000,
  };
  if (overrides.includeContext !== false) {
    payload.sanitizedContext = {
      capturedAt: "2026-07-22T10:00:00.000Z",
      applicationName: "Preview",
      bundleIdentifier: "com.apple.Preview",
      windowTitle: "Paper: Attention and Executive Function",
      selectedText: "task resumption after interruption",
      semanticTags: ["reading", "paper"],
      isSensitive: false,
      ...(overrides.context ?? {}),
    };
  }
  return { version: 1, id, type: "chat", payload };
}

function toolCallEvents(): Record<string, unknown>[] {
  const argumentsJson = JSON.stringify({ taskTitle: "完成论文引言", note: "回到刚才的论文现场" });
  return [
    { type: "response.created", response: { id: "resp-tool", status: "in_progress" } },
    {
      type: "response.output_item.added",
      output_index: 0,
      item: { id: "fc-return", type: "function_call", status: "in_progress", arguments: "", call_id: "call-return", name: "show_return_card" },
    },
    { type: "response.function_call_arguments.delta", item_id: "fc-return", output_index: 0, delta: argumentsJson },
    { type: "response.function_call_arguments.done", item_id: "fc-return", output_index: 0, arguments: argumentsJson },
    {
      type: "response.output_item.done",
      output_index: 0,
      item: { id: "fc-return", type: "function_call", status: "completed", arguments: argumentsJson, call_id: "call-return", name: "show_return_card" },
    },
    { type: "response.completed", response: completedResponse("resp-tool", 110, 18) },
  ];
}

function textEvents(): Record<string, unknown>[] {
  const text = "我把刚才的论文线索放回你手边了。";
  return [
    { type: "response.created", response: { id: "resp-text", status: "in_progress" } },
    {
      type: "response.output_item.added",
      output_index: 0,
      item: { id: "msg-cloud", type: "message", role: "assistant", status: "in_progress", content: [] },
    },
    {
      type: "response.content_part.added",
      item_id: "msg-cloud",
      output_index: 0,
      content_index: 0,
      part: { type: "output_text", text: "", annotations: [] },
    },
    { type: "response.output_text.delta", item_id: "msg-cloud", output_index: 0, content_index: 0, delta: text },
    {
      type: "response.output_item.done",
      output_index: 0,
      item: { id: "msg-cloud", type: "message", role: "assistant", status: "completed", content: [{ type: "output_text", text, annotations: [] }] },
    },
    { type: "response.completed", response: completedResponse("resp-text", 150, 24) },
  ];
}

function completedResponse(id: string, inputTokens: number, outputTokens: number): Record<string, unknown> {
  return {
    id,
    status: "completed",
    output: [],
    usage: {
      input_tokens: inputTokens,
      output_tokens: outputTokens,
      total_tokens: inputTokens + outputTokens,
      input_tokens_details: { cached_tokens: 0 },
    },
  };
}

function chatToolCallEvents(): Record<string, unknown>[] {
  const argumentsJson = JSON.stringify({ taskTitle: "完成论文引言", note: "回到刚才的论文现场" });
  return [
    {
      id: "chatcmpl-tool",
      object: "chat.completion.chunk",
      created: 1_700_000_000,
      model: "agentone-cloud-test-model",
      choices: [{
        index: 0,
        delta: {
          role: "assistant",
          tool_calls: [{
            index: 0,
            id: "call-return",
            type: "function",
            function: { name: "show_return_card", arguments: argumentsJson },
          }],
        },
        finish_reason: null,
      }],
    },
    {
      id: "chatcmpl-tool",
      object: "chat.completion.chunk",
      created: 1_700_000_000,
      model: "agentone-cloud-test-model",
      choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }],
      usage: { prompt_tokens: 110, completion_tokens: 18, total_tokens: 128 },
    },
  ];
}

function chatTextEvents(): Record<string, unknown>[] {
  const text = "我把刚才的论文线索放回你手边了。";
  return [
    {
      id: "chatcmpl-text",
      object: "chat.completion.chunk",
      created: 1_700_000_001,
      model: "agentone-cloud-test-model",
      choices: [{ index: 0, delta: { role: "assistant", content: text }, finish_reason: null }],
    },
    {
      id: "chatcmpl-text",
      object: "chat.completion.chunk",
      created: 1_700_000_001,
      model: "agentone-cloud-test-model",
      choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
      usage: { prompt_tokens: 150, completion_tokens: 24, total_tokens: 174 },
    },
  ];
}

function anthropicToolCallEvents(): Record<string, unknown>[] {
  const argumentsJson = JSON.stringify({ taskTitle: "完成论文引言", note: "回到刚才的论文现场" });
  return [
    {
      type: "message_start",
      message: {
        id: "msg-kimi-tool",
        type: "message",
        role: "assistant",
        model: "kimi-for-coding",
        content: [],
        stop_reason: null,
        stop_sequence: null,
        usage: { input_tokens: 110, output_tokens: 0 },
      },
    },
    {
      type: "content_block_start",
      index: 0,
      content_block: {
        type: "tool_use",
        id: "kimi-call-return",
        name: "show_return_card",
        input: {},
      },
    },
    {
      type: "content_block_delta",
      index: 0,
      delta: { type: "input_json_delta", partial_json: argumentsJson },
    },
    { type: "content_block_stop", index: 0 },
    {
      type: "message_delta",
      delta: { stop_reason: "tool_use", stop_sequence: null },
      usage: { output_tokens: 18 },
    },
    { type: "message_stop" },
  ];
}

function anthropicTextEvents(responseText = "我把刚才的论文线索放回你手边了。"): Record<string, unknown>[] {
  return [
    {
      type: "message_start",
      message: {
        id: "msg-kimi-text",
        type: "message",
        role: "assistant",
        model: "kimi-for-coding",
        content: [],
        stop_reason: null,
        stop_sequence: null,
        usage: { input_tokens: 150, output_tokens: 0 },
      },
    },
    {
      type: "content_block_start",
      index: 0,
      content_block: { type: "text", text: "" },
    },
    {
      type: "content_block_delta",
      index: 0,
      delta: { type: "text_delta", text: responseText },
    },
    { type: "content_block_stop", index: 0 },
    {
      type: "message_delta",
      delta: { stop_reason: "end_turn", stop_sequence: null },
      usage: { output_tokens: 24 },
    },
    { type: "message_stop" },
  ];
}

function terminal(responses: WireResponse[]): WireResponse {
  const response = responses.at(-1);
  assert.ok(response);
  assert.ok(response.type === "ready" || response.type === "result" || response.type === "error");
  return response;
}

function record(value: unknown): Record<string, unknown> {
  assert.ok(typeof value === "object" && value !== null && !Array.isArray(value));
  return value as Record<string, unknown>;
}

test("OpenAI-compatible cloud routing works through the compiled JSONL sidecar", async (t) => {
  const mock = new OpenAIResponsesMock();
  await mock.start();
  const sidecar = new CloudSidecar({
    AGENTONE_MODEL_ROUTE: "cloud",
    AGENTONE_MODEL_ID: "agentone-cloud-test-model",
    AGENTONE_OPENAI_BASE_URL: mock.baseUrl,
    OPENAI_API_KEY: "sk-test-agentone-cloud",
  });
  try {
    await t.test("health exposes cloud provider metadata", async () => {
      const response = terminal(await sidecar.request({ version: 1, id: "cloud-health", type: "health" }));
      assert.equal(response.type, "ready");
      const payload = record(response.payload);
      assert.equal(payload.runtimeMode, "cloud");
      assert.equal(payload.provider, "openai-compatible-completions");
      assert.equal(payload.model, "agentone-cloud-test-model");
    });

    await t.test("Authorization, context, tools, tool result round-trip, and result metadata are preserved", async () => {
      mock.setMode("success");
      const response = terminal(await sidecar.request(wakeRequest("cloud-success")));
      assert.equal(response.type, "result");
      assert.equal(mock.requests.length, 2);
      const [first, second] = mock.requests;
      assert.ok(first);
      assert.ok(second);
      assert.equal(first.method, "POST");
      assert.equal(first.url, "/algo/chat/completions");
      assert.equal(first.authorization, "Bearer sk-test-agentone-cloud");
      assert.equal(first.body.model, "agentone-cloud-test-model");
      assert.equal(first.body.stream, true);
      assert.ok(Array.isArray(first.body.messages));
      assert.ok(Array.isArray(first.body.tools));
      const firstBody = JSON.stringify(first.body);
      assert.match(firstBody, /Paper: Attention and Executive Function/u);
      assert.match(firstBody, /正在整理执行功能相关论文笔记/u);
      assert.match(firstBody, /show_return_card/u);
      assert.doesNotMatch(firstBody, /shell_exec/u);

      assert.equal(second.authorization, "Bearer sk-test-agentone-cloud");
      const secondBody = JSON.stringify(second.body);
      assert.match(secondBody, /tool/u);
      assert.match(secondBody, /call-return/u);
      assert.match(secondBody, /accepted/u);

      const payload = record(response.payload);
      const actions = payload.actions;
      assert.ok(Array.isArray(actions));
      assert.deepEqual(actions.map((action) => record(action).type), ["return_card"]);
      assert.equal(payload.spokenText, "我把刚才的论文线索放回你手边了。");
      assert.deepEqual(payload.model, {
        route: "cloud",
        provider: "openai-compatible-completions",
        model: "agentone-cloud-test-model",
      });
    });

    await t.test("Chat sends ordered history, authorized Context, Memory, model, and bearer token", async () => {
      mock.setMode("success");
      const before = mock.requests.length;
      const response = terminal(await sidecar.request(chatRequest("cloud-chat-context")));
      assert.equal(response.type, "result");
      assert.equal(mock.requests.length, before + 1);
      const request = mock.requests.at(-1);
      assert.ok(request);
      assert.equal(request.url, "/algo/chat/completions");
      assert.equal(request.authorization, "Bearer sk-test-agentone-cloud");
      assert.equal(request.body.model, "agentone-cloud-test-model");
      const body = JSON.stringify(request.body);
      assert.match(body, /刚才我在看什么/u);
      assert.match(body, /你在读一篇注意力相关论文/u);
      assert.match(body, /帮我接着整理下一步/u);
      assert.ok(body.indexOf("刚才我在看什么") < body.indexOf("帮我接着整理下一步"));
      assert.match(body, /Paper: Attention and Executive Function/u);
      assert.match(body, /task resumption after interruption/u);
      assert.match(body, /用户在整理执行功能论文的论点/u);
      const payload = record(response.payload);
      assert.equal(payload.spokenText, "我把刚才的论文线索放回你手边了。");
      assert.deepEqual(payload.model, {
        route: "cloud",
        provider: "openai-compatible-completions",
        model: "agentone-cloud-test-model",
      });
    });

    await t.test("Chat omits current Context when the user disables citation", async () => {
      mock.setMode("success");
      const before = mock.requests.length;
      const response = terminal(await sidecar.request(chatRequest("cloud-chat-no-context", {
        includeContext: false,
        memory: [],
      })));
      assert.equal(response.type, "result");
      assert.equal(mock.requests.length, before + 1);
      const request = mock.requests.at(-1);
      assert.ok(request);
      const body = JSON.stringify(request.body);
      assert.match(body, /Current Context: not shared for this turn/u);
      assert.doesNotMatch(body, /task resumption after interruption/u);
      assert.doesNotMatch(body, /用户在整理执行功能论文的论点/u);
    });

    for (const [mode, status, rawSecret] of [
      ["unauthorized", 401, "raw-401-provider-secret"],
      ["server-error", 500, "raw-500-upstream-database-detail"],
    ] as const) {
      await t.test(`${status} provider errors are stable and sanitized`, async () => {
        mock.setMode(mode);
        const response = terminal(await sidecar.request(wakeRequest(`cloud-error-${status}`)));
        assert.equal(response.type, "error");
        const payload = record(response.payload);
        assert.equal(payload.code, "model_request_failed");
        assert.equal(payload.message, `Cloud model request failed (${status}).`);
        assert.equal(payload.retryable, true);
        const serialized = JSON.stringify(payload);
        assert.doesNotMatch(serialized, new RegExp(rawSecret, "u"));
        assert.doesNotMatch(serialized, /sk-test-agentone-cloud/u);
        assert.doesNotMatch(serialized, /mock_provider_error/u);
      });
    }

    await t.test("sensitive context and recent memory are blocked before HTTP", async () => {
      const before = mock.requests.length;
      const contextBlocked = terminal(await sidecar.request(wakeRequest("cloud-sensitive-context", {
        context: { isSensitive: true, windowTitle: "支付密码" },
      })));
      assert.equal(contextBlocked.type, "error");
      assert.equal(record(contextBlocked.payload).code, "context_blocked");
      assert.equal(mock.requests.length, before);

      const memoryBlocked = terminal(await sidecar.request(wakeRequest("cloud-sensitive-memory", {
        memory: [{
          id: "sensitive-cloud-memory",
          timestamp: "2026-07-22T03:01:00.000Z",
          kind: "chat",
          summary: "银行卡验证码 123456",
          tags: ["private"],
        }],
      })));
      assert.equal(memoryBlocked.type, "error");
      assert.equal(record(memoryBlocked.payload).code, "context_blocked");
      assert.equal(mock.requests.length, before);
    });

    await t.test("sensitive Chat Context and Memory cause zero HTTP requests", async () => {
      const before = mock.requests.length;
      const contextBlocked = terminal(await sidecar.request(chatRequest("cloud-chat-sensitive-context", {
        context: { isSensitive: true, windowTitle: "支付密码" },
      })));
      assert.equal(contextBlocked.type, "error");
      assert.equal(record(contextBlocked.payload).code, "context_blocked");
      assert.equal(mock.requests.length, before);

      const memoryBlocked = terminal(await sidecar.request(chatRequest("cloud-chat-sensitive-memory", {
        includeContext: false,
        memory: [{
          id: "sensitive-chat-memory",
          timestamp: "2026-07-22T03:01:00.000Z",
          kind: "chat",
          summary: "支付验证码 123456",
          tags: ["private"],
        }],
      })));
      assert.equal(memoryBlocked.type, "error");
      assert.equal(record(memoryBlocked.payload).code, "context_blocked");
      assert.equal(mock.requests.length, before);
    });

    await t.test("Chat provider failures are sanitized without exposing the API key", async () => {
      mock.setMode("unauthorized");
      const response = terminal(await sidecar.request(chatRequest("cloud-chat-unauthorized")));
      assert.equal(response.type, "error");
      const payload = record(response.payload);
      assert.equal(payload.code, "model_request_failed");
      assert.equal(payload.message, "Cloud model request failed (401).");
      const serialized = JSON.stringify(payload);
      assert.doesNotMatch(serialized, /sk-test-agentone-cloud/u);
      assert.doesNotMatch(serialized, /raw-401-provider-secret/u);
    });

    await sidecar.shutdown();
    sidecar.assertSecretAbsent("sk-test-agentone-cloud");
  } finally {
    await sidecar.dispose();
    await mock.stop();
  }
});

test("Kimi OAuth routing takes precedence and uses the Anthropic Messages contract", async (t) => {
  const mock = new OpenAIResponsesMock();
  await mock.start();
  const accessToken = "agentone-kimi-token-canary-N8k4Q2";
  const expectedDeviceHeaders = {
    "X-Msh-Platform": "macOS",
    "X-Msh-Version": "0.29.0",
    "X-Msh-Device-Name": "AgentOne",
    "X-Msh-Device-Model": "Mac",
    "X-Msh-Os-Version": "15.0",
    "X-Msh-Device-Id": "agentone-test-device",
  };
  const sidecar = new CloudSidecar({
    AGENTONE_MODEL_ROUTE: "cloud",
    AGENTONE_KIMI_BASE_URL: mock.kimiBaseUrl,
    AGENTONE_KIMI_ACCESS_TOKEN: accessToken,
    AGENTONE_KIMI_PLATFORM: expectedDeviceHeaders["X-Msh-Platform"],
    AGENTONE_KIMI_VERSION: expectedDeviceHeaders["X-Msh-Version"],
    AGENTONE_KIMI_DEVICE_NAME: expectedDeviceHeaders["X-Msh-Device-Name"],
    AGENTONE_KIMI_DEVICE_MODEL: expectedDeviceHeaders["X-Msh-Device-Model"],
    AGENTONE_KIMI_OS_VERSION: expectedDeviceHeaders["X-Msh-Os-Version"],
    AGENTONE_KIMI_DEVICE_ID: expectedDeviceHeaders["X-Msh-Device-Id"],
    OPENAI_API_KEY: "sk-api-key-must-not-win",
  });
  try {
    await t.test("health reports the Kimi provider and default model", async () => {
      const response = terminal(await sidecar.request({ version: 1, id: "kimi-health", type: "health" }));
      assert.equal(response.type, "ready");
      const payload = record(response.payload);
      assert.equal(payload.runtimeMode, "cloud");
      assert.equal(payload.provider, "kimi-coding");
      assert.equal(payload.model, "kimi-for-coding");
    });

    await t.test("Kimi path, OAuth token, device identity, and two-turn tool execution are preserved", async () => {
      mock.setMode("success");
      const response = terminal(await sidecar.request(wakeRequest("kimi-success")));
      assert.equal(response.type, "result");
      assert.equal(mock.requests.length, 2);
      const [first, second] = mock.requests;
      assert.ok(first);
      assert.ok(second);
      assert.equal(first.method, "POST");
      assert.equal(first.url, "/coding/v1/messages");
      assert.equal(first.apiKey, accessToken);
      assert.equal(first.authorization, undefined);
      assert.equal(first.anthropicVersion, "2023-06-01");
      assert.match(first.userAgent ?? "", /KimiCLI\/1\.5/u);
      assert.deepEqual(first.kimiHeaders, expectedDeviceHeaders);
      assert.equal(first.accept, "application/json");
      assert.equal(first.body.model, "kimi-for-coding");
      assert.ok(Array.isArray(first.body.system));
      assert.equal(first.body.tool_choice, undefined);
      assert.equal(first.body.stream, true);
      assert.ok(Array.isArray(first.body.messages));
      assert.ok(Array.isArray(first.body.tools));
      assert.notEqual(first.apiKey, "sk-api-key-must-not-win");
      assert.match(JSON.stringify(first.body), /Attention and Executive Function/u);

      assert.equal(second.url, "/coding/v1/messages");
      assert.equal(second.apiKey, accessToken);
      assert.deepEqual(second.kimiHeaders, expectedDeviceHeaders);
      assert.equal(second.accept, "application/json");
      assert.match(JSON.stringify(second.body), /tool_result/u);

      const payload = record(response.payload);
      assert.deepEqual(payload.model, {
        route: "cloud",
        provider: "kimi-coding",
        model: "kimi-for-coding",
      });
      const actions = payload.actions;
      assert.ok(Array.isArray(actions));
      assert.deepEqual(actions.map((action) => record(action).type), ["return_card"]);
    });

    await t.test("Kimi OAuth Chat uses the Anthropic contract and includes authorized Context", async () => {
      mock.setMode("success");
      const before = mock.requests.length;
      const response = terminal(await sidecar.request(chatRequest("kimi-chat-context")));
      assert.equal(response.type, "result");
      assert.equal(mock.requests.length, before + 1);
      const request = mock.requests.at(-1);
      assert.ok(request);
      assert.equal(request.url, "/coding/v1/messages");
      assert.equal(request.apiKey, accessToken);
      assert.deepEqual(request.kimiHeaders, expectedDeviceHeaders);
      assert.equal(request.body.model, "kimi-for-coding");
      assert.ok(request.body.thinking, "ordinary Kimi chat should retain its configured thinking mode");
      const body = JSON.stringify(request.body);
      assert.match(body, /帮我接着整理下一步/u);
      assert.match(body, /Paper: Attention and Executive Function/u);
      assert.match(body, /用户在整理执行功能论文的论点/u);
      const payload = record(response.payload);
      assert.equal(payload.spokenText, "我把刚才的论文线索放回你手边了。");
      assert.deepEqual(payload.model, {
        route: "cloud",
        provider: "kimi-coding",
        model: "kimi-for-coding",
      });
    });

    await t.test("Kimi Context enrichment receives submitted text, screenshot OCR, click target, and transition", async () => {
      mock.setMode("success");
      const before = mock.requests.length;
      const response = terminal(await sidecar.request(chatRequest("kimi-context-enrichment", {
        purpose: "context_enrichment",
        messages: [{ role: "user", content: "用户按下回车并完成一次观点提交" }],
        memory: [],
        context: {
          submittedText: "重新修一下，让这些功能真正落地。",
          screenText: "AgentOne 回车关键截图 OCR：讨论为什么支付密码不能被采集",
          interactionTarget: "Button · 打开研究文档",
          contextTransition: "点击后从 ChatGPT 前往论文页面",
        },
      })));
      assert.equal(response.type, "result");
      assert.equal(mock.requests.length, before + 1);
      const request = mock.requests.at(-1);
      assert.ok(request);
      assert.equal(request.url, "/coding/v1/messages");
      assert.deepEqual(
        request.body.thinking,
        { type: "disabled" },
        "strict Context JSON must explicitly disable Kimi thinking at the HTTP contract",
      );
      const body = JSON.stringify(request.body);
      assert.match(body, /重新修一下，让这些功能真正落地/u);
      assert.match(body, /讨论为什么支付密码不能被采集/u);
      assert.match(body, /Button · 打开研究文档/u);
      assert.match(body, /点击后从 ChatGPT 前往论文页面/u);
      assert.match(body, /activity_title/u);
      const payload = record(response.payload);
      assert.equal(payload.outcome, "context_enriched");
      const analysis = record(JSON.parse(String(payload.spokenText)));
      assert.equal(analysis.activity_title, "提交 AgentOne Context 识别问题");
      assert.match(String(analysis.summary), /本次回车提交的具体原文/u);
      assert.deepEqual(payload.model, {
        route: "cloud",
        provider: "kimi-coding",
        model: "kimi-for-coding",
      });
    });

    await t.test("Kimi daily digest receives distilled Context plus relationship memory and returns strict JSON", async () => {
      mock.setMode("success");
      const before = mock.requests.length;
      const response = terminal(await sidecar.request(chatRequest("kimi-daily-digest", {
        purpose: "daily_digest",
        messages: [{ role: "user", content: "请整理 2026-08-04 的活日记" }],
        includeContext: false,
        memory: [
          {
            id: "context-1",
            timestamp: "2026-08-04T06:00:00.000Z",
            kind: "daily_context",
            summary: "明确日记需要按一天的 Context 提炼主线，而不是应用流水",
            tags: ["daily-context", "output"],
          },
          {
            id: "habit-1",
            timestamp: "2026-07-29T06:00:00.000Z",
            kind: "habit_context",
            summary: "用户会反复验证功能是否真实落地，不接受只做演示",
            tags: ["relationship-memory"],
          },
        ],
      })));
      assert.equal(response.type, "result");
      assert.equal(mock.requests.length, before + 1);
      const request = mock.requests.at(-1);
      assert.ok(request);
      assert.deepEqual(request.body.thinking, { type: "disabled" });
      const body = JSON.stringify(request.body);
      assert.match(body, /日记需要按一天的 Context 提炼主线/u);
      assert.match(body, /不接受只做演示/u);
      assert.match(body, /unfinished_thread/u);
      const payload = record(response.payload);
      assert.equal(payload.outcome, "daily_digest_created");
      const digest = record(JSON.parse(String(payload.spokenText)));
      assert.match(String(digest.headline), /AgentOne/u);
      assert.match(String(digest.agent_note), /记录器/u);
      assert.equal(digest.mood, "thoughtful");
    });

    await t.test("provider failures are sanitized without exposing the OAuth token", async () => {
      mock.setMode("unauthorized");
      const response = terminal(await sidecar.request(wakeRequest("kimi-unauthorized")));
      assert.equal(response.type, "error");
      const payload = record(response.payload);
      assert.equal(payload.code, "model_request_failed");
      assert.equal(payload.message, "Cloud model request failed (401).");
      const serialized = JSON.stringify(payload);
      assert.doesNotMatch(serialized, new RegExp(accessToken, "u"));
      assert.doesNotMatch(serialized, /sk-api-key-must-not-win/u);
      assert.doesNotMatch(serialized, /raw-401-provider-secret/u);
    });

    await t.test("sensitive Context and Memory cause zero Kimi HTTP requests", async () => {
      const before = mock.requests.length;
      const contextBlocked = terminal(await sidecar.request(wakeRequest("kimi-sensitive-context", {
        context: { isSensitive: true, windowTitle: "支付密码" },
      })));
      assert.equal(contextBlocked.type, "error");
      assert.equal(record(contextBlocked.payload).code, "context_blocked");
      assert.equal(mock.requests.length, before);

      const memoryBlocked = terminal(await sidecar.request(wakeRequest("kimi-sensitive-memory", {
        memory: [{
          id: "sensitive-kimi-memory",
          timestamp: "2026-07-22T03:01:00.000Z",
          kind: "chat",
          summary: "银行卡验证码 123456",
          tags: ["private"],
        }],
      })));
      assert.equal(memoryBlocked.type, "error");
      assert.equal(record(memoryBlocked.payload).code, "context_blocked");
      assert.equal(mock.requests.length, before);
    });

    await sidecar.shutdown();
    sidecar.assertSecretAbsent(accessToken);
    sidecar.assertSecretAbsent("sk-api-key-must-not-win");
  } finally {
    await sidecar.dispose();
    await mock.stop();
  }
});

test("cloud route without Kimi or API credentials automatically runs offline", async () => {
  const sidecar = new CloudSidecar({ AGENTONE_MODEL_ROUTE: "cloud" });
  try {
    const response = terminal(await sidecar.request({ version: 1, id: "credentialless-health", type: "health" }));
    assert.equal(response.type, "ready");
    const payload = record(response.payload);
    assert.equal(payload.runtimeMode, "offline-faux");
    assert.equal(payload.provider, "agentone-offline");
    assert.equal(payload.model, "agentone-policy-v1");
    await sidecar.shutdown();
  } finally {
    await sidecar.dispose();
  }
});
