import assert from "node:assert/strict";
import test from "node:test";
import { once } from "node:events";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { getCurrentSystemPrompt, getCurrentTools, normalizeContext, Type, type Model } from "@earendil-works/pi-ai";
import { convertAgentOneMessages, transformAgentOneContext } from "../src/custom-messages.js";
import { nonStreamingCompletions } from "../src/non-streaming.js";

test("Pi 1.x system prompt and tool declarations survive context trimming and conversion", async () => {
  const system: AgentMessage = { role: "system", content: "Use only authorized tools.", timestamp: 1,
    toolsAdded: [{ name: "safe_tool", description: "An authorized action", parameters: Type.Object({}) }] };
  const transcript: AgentMessage[] = [system, ...Array.from({ length: 25 }, (_, i): AgentMessage =>
    ({ role: "user", content: `message ${i}`, timestamp: i + 2 }))];
  const converted = convertAgentOneMessages(await transformAgentOneContext(transcript));
  assert.equal(converted.length, 17);
  assert.equal(converted[0]?.role, "system");
  assert.equal(getCurrentSystemPrompt(converted), "Use only authorized tools.");
  assert.deepEqual(getCurrentTools(converted).map(tool => tool.name), ["safe_tool"]);
  assert.equal(converted[1]?.role === "user" && converted[1].content, "message 9");
});

test("non-streaming HTTP replays system sections and tool additions/removals from Pi 1.x transcript", async () => {
  let captured: { messages: { role: string; content: string }[]; tools: { function: { name: string } }[] } | undefined;
  const server = createServer(async (request, response) => {
    let body = "";
    for await (const chunk of request) body += chunk;
    captured = JSON.parse(body) as typeof captured;
    response.setHeader("Content-Type", "application/json");
    response.end(JSON.stringify({ choices: [{ message: { content: "done" }, finish_reason: "stop" }] }));
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  try {
    const model: Model<"openai-completions"> = { id: "fixture", name: "Fixture", api: "openai-completions", provider: "fixture",
      baseUrl: `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1`, reasoning: false, input: ["text"],
      contextWindow: 4096, maxTokens: 256, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
    const tool = (name: string) => ({ name, description: name, parameters: Type.Object({}) });
    const context = normalizeContext({ systemPrompt: "Base instruction.", tools: [tool("old_tool")], messages: [
      { role: "user", content: "first", timestamp: 1 },
      { role: "system", content: "Updated instruction.", sections: { policy: "Retain evidence." },
        toolsRemoved: [{ name: "old_tool" }], toolsAdded: [tool("new_tool")], timestamp: 2 },
      { role: "user", content: "second", timestamp: 3 },
    ] });
    const stream = await nonStreamingCompletions(model, context, { apiKey: "fixture" });
    const events: string[] = [];
    for await (const event of stream) events.push(event.type);
    assert.equal((await stream.result()).stopReason, "stop");
    assert.deepEqual(events, ["start", "done"]);
    assert.ok(captured);
    assert.deepEqual(captured.tools.map(tool => tool.function.name), ["new_tool"]);
    assert.equal(captured.messages[0]?.role, "system");
    assert.match(captured.messages[0]?.content ?? "", /Base instruction[\s\S]*Updated instruction[\s\S]*Retain evidence/);
    assert.deepEqual(captured.messages.slice(1).map(message => message.content), ["first", "second"]);
  } finally {
    server.close();
    await once(server, "close");
  }
});
