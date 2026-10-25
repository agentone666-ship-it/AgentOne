import assert from "node:assert/strict";
import test from "node:test";
import { chatCompletionsEndpoint, chatCompletionsBaseURL } from "../src/completions-url.js";
import { runtimeModelConfigurationFromEnvironment } from "../src/life-agent.js";

test("base and full completion URLs resolve identically, including trailing slashes", () => {
  const base = "https://api.example.com/step_plan/v1";
  for (const input of [base, `${base}/`, `${base}/chat/completions`, `${base}/chat/completions/`]) {
    assert.equal(chatCompletionsEndpoint(input), `${base}/chat/completions`);
    assert.equal(chatCompletionsBaseURL(input), base);
  }
  assert.equal(chatCompletionsEndpoint(`${base}/chat/completions?version=1`), `${base}/chat/completions?version=1`);
  assert.equal(chatCompletionsEndpoint(`${base}?version=1`), `${base}/chat/completions?version=1`);
});

test("configured full endpoint is normalized for both streaming and non-streaming providers", () => {
  const model = runtimeModelConfigurationFromEnvironment({ AGENTONE_MODEL_ROUTE: "cloud", OPENAI_API_KEY: "fixture-key",
    AGENTONE_OPENAI_BASE_URL: "https://api.example.com/step_plan/v1/chat/completions", AGENTONE_MODEL_ID: "fixture-model" });
  assert.equal(model.baseUrl, "https://api.example.com/step_plan/v1");
});
