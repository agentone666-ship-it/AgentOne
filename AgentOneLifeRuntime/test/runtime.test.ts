import assert from "node:assert/strict";
import test from "node:test";
import {
  runOfflineWake,
  runtimeModelConfigurationFromEnvironment,
  RuntimePolicyError,
} from "../src/life-agent.js";
import { defaultBudget, parseRequest, type WakePayload } from "../src/protocol.js";
import { handleLine } from "../src/server.js";

function payload(overrides: Partial<WakePayload> = {}): WakePayload {
  return {
    reason: "drift_detected",
    sanitizedContext: {
      capturedAt: "2026-07-21T08:00:00.000Z",
      applicationName: "Safari",
      windowTitle: "A tempting unrelated video",
      semanticTags: ["video"],
      isSensitive: false,
      activeIntent: { id: "intent-1", title: "完成论文引言" },
      driftDurationSeconds: 70,
    },
    recentMemory: [{ id: "m1", timestamp: "2026-07-21T07:55:00.000Z", kind: "activity", summary: "正在修改论文引言", tags: ["论文"] }],
    budget: defaultBudget(),
    ...overrides,
  };
}

test("parses and clamps a wake request", () => {
  const request = parseRequest(JSON.stringify({
    version: 1,
    id: "request-1",
    type: "wake",
    payload: { ...payload(), budget: { ...defaultBudget(), maxTurns: 99, maxDurationMs: 1 } },
  }));
  assert.equal(request.type, "wake");
  if (request.type === "wake") {
    assert.equal(request.payload.budget.maxTurns, 12);
    assert.equal(request.payload.budget.maxDurationMs, 500);
  }
});

test("parses daily digest chat with a wider bounded Context memory window", () => {
  const recentMemory = Array.from({ length: 80 }, (_, index) => ({
    id: `context-${index}`,
    timestamp: "2026-08-04T08:00:00.000Z",
    kind: index % 2 === 0 ? "daily_context" : "habit_context",
    summary: `第 ${index} 段语义 Context`,
    tags: ["daily-context"],
  }));
  const request = parseRequest(JSON.stringify({
    version: 1,
    id: "digest-1",
    type: "chat",
    payload: {
      purpose: "daily_digest",
      messages: [{ role: "user", content: "整理今天" }],
      recentMemory,
      maxTokens: 2_200,
      maxDurationMs: 45_000,
    },
  }));
  assert.equal(request.type, "chat");
  if (request.type === "chat") {
    assert.equal(request.payload.purpose, "daily_digest");
    assert.equal(request.payload.recentMemory.length, 64);
    assert.equal(request.payload.recentMemory[0]?.id, "context-16");
  }
});

test("runs a Pi tool loop and returns only proposed safe actions", async () => {
  const result = await runOfflineWake(payload());
  assert.equal(result.outcome, "actions_proposed");
  assert.ok(result.actions.some((action) => action.type === "return_card"));
  assert.ok(result.actions.some((action) => action.type === "inner_journal"));
  assert.ok(result.actions.some((action) => action.type === "energy_consumed"));
  assert.ok(result.usage.toolCalls >= 3);
  assert.equal(result.usage.stoppedByBudget, false);
});

test("sensitive context is blocked before Pi sees it", async () => {
  await assert.rejects(
    runOfflineWake(payload({ sanitizedContext: { ...payload().sanitizedContext, isSensitive: true } })),
    (error: unknown) => error instanceof RuntimePolicyError && error.code === "context_blocked",
  );
});

test("tool allowlist prevents unapproved actions", async () => {
  const result = await runOfflineWake(payload({
    budget: { ...defaultBudget(), allowedTools: ["get_current_context"] },
  }));
  assert.deepEqual(result.actions, []);
});

test("JSONL server health response describes the pinned runtime", async () => {
  const responses: unknown[] = [];
  const outcome = await handleLine(JSON.stringify({ version: 1, id: "health-1", type: "health" }), (response) => responses.push(response));
  assert.equal(outcome, "continue");
  assert.equal((responses[0] as { type: string }).type, "ready");
});

test("API Key route defaults to the approved GLM Chat Completions service", () => {
  const configuration = runtimeModelConfigurationFromEnvironment({
    AGENTONE_MODEL_ROUTE: "cloud",
    OPENAI_API_KEY: "test-canary-only",
  });
  assert.deepEqual(configuration, {
    route: "cloud",
    provider: "openai-compatible-completions",
    model: "glm-5.2",
    apiKey: "test-canary-only",
  });
});

test("local route configures Ollama without a user API key", () => {
  const configuration = runtimeModelConfigurationFromEnvironment({
    AGENTONE_MODEL_ROUTE: "local",
  });
  assert.deepEqual(configuration, {
    route: "local",
    provider: "ollama",
    model: "llama3.2:3b",
    apiKey: "ollama-local",
    baseUrl: "http://127.0.0.1:11434/v1",
  });
});

test("custom GLM URL is normalized while arbitrary cleartext endpoints are rejected", () => {
  const approved = runtimeModelConfigurationFromEnvironment({
    AGENTONE_MODEL_ROUTE: "cloud",
    AGENTONE_MODEL_ID: "glm-5.2",
    AGENTONE_OPENAI_BASE_URL: "http://algoagent.zhuaninc.com/algo///",
    OPENAI_API_KEY: "test-canary-only",
  });
  assert.equal(approved.baseUrl, "http://algoagent.zhuaninc.com/algo");

  const rejected = runtimeModelConfigurationFromEnvironment({
    AGENTONE_MODEL_ROUTE: "cloud",
    AGENTONE_OPENAI_BASE_URL: "http://untrusted.example/algo",
    OPENAI_API_KEY: "test-canary-only",
  });
  assert.equal(rejected.baseUrl, undefined);
});

test("Kimi OAuth still takes precedence over an API Key fallback", () => {
  const configuration = runtimeModelConfigurationFromEnvironment({
    AGENTONE_MODEL_ROUTE: "cloud",
    AGENTONE_KIMI_ACCESS_TOKEN: "oauth-canary",
    AGENTONE_KIMI_BASE_URL: "https://api.kimi.com/coding",
    AGENTONE_KIMI_PLATFORM: "macOS",
    AGENTONE_KIMI_VERSION: "0.29.0",
    AGENTONE_KIMI_DEVICE_NAME: "AgentOne",
    AGENTONE_KIMI_DEVICE_MODEL: "Mac",
    AGENTONE_KIMI_OS_VERSION: "15.0",
    AGENTONE_KIMI_DEVICE_ID: "agentone-device",
    AGENTONE_OPENAI_BASE_URL: "http://algoagent.zhuaninc.com/algo",
    OPENAI_API_KEY: "api-key-canary",
  });
  assert.equal(configuration.provider, "kimi-coding");
  assert.equal(configuration.model, "kimi-for-coding");
  assert.equal(configuration.apiKey, "oauth-canary");
  assert.equal(configuration.baseUrl, "https://api.kimi.com/coding");
  assert.deepEqual(configuration.headers, {
    "X-Msh-Platform": "macOS",
    "X-Msh-Version": "0.29.0",
    "X-Msh-Device-Name": "AgentOne",
    "X-Msh-Device-Model": "Mac",
    "X-Msh-Os-Version": "15.0",
    "X-Msh-Device-Id": "agentone-device",
  });
});
