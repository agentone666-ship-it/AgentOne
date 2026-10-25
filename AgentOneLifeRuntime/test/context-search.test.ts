import assert from "node:assert/strict";
import test from "node:test";
import { once } from "node:events";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { searchContext } from "../src/context-search.js";
import { runChat } from "../src/life-agent.js";
import { parseRequest, type ContextRecord } from "../src/protocol.js";

const row = (id: string, timestamp: string, url = "https://www.zhihu.com/question/123"): ContextRecord => ({
  id, eventID: `event-${id}`, timestamp, kind: "reading",
  context: { capturedAt: timestamp, applicationName: "Google Chrome", bundleIdentifier: "com.google.Chrome", url,
    windowTitle: "关于注意力的帖子", contentSummary: "阅读注意力训练方法", semanticTags: ["readingProgress"], isSensitive: false },
});
const records = [row("morning", "2026-09-29T01:00:00Z"), row("noon", "2026-09-29T04:00:00Z"),
  row("yesterday", "2026-09-28T01:00:00Z"), row("spoof", "2026-09-29T01:00:00Z", "https://evilzhihu.com/question")];

test("local morning, app, domain, Chinese terms and tags combine; noon is exclusive", () => {
  const result = searchContext(records, "Asia/Shanghai", { localDate: "2026-09-29", startHour: 6, endHour: 12,
    application: "CHROME", domain: "zhihu.com", query: "注意力 训练", tags: ["readingProgress"] });
  assert.deepEqual(result.results.map(r => r.id), ["morning"]);
  assert.equal(result.totalMatches, 1);
});

test("absolute ranges, stable pagination and event lookup", () => {
  const first = searchContext(records, "Asia/Shanghai", { startTime: "2026-09-29T00:00:00+08:00", endTime: "2026-09-30T00:00:00+08:00", limit: 1 });
  assert.equal(first.totalMatches, 3);
  assert.equal(first.nextOffset, 1);
  assert.equal(first.results[0]?.id, "noon");
  assert.equal(searchContext(records, "UTC", { eventID: "event-yesterday" }).results[0]?.id, "yesterday");
  assert.equal(searchContext(records, "UTC", { query: "不存在" }).totalMatches, 0);
  assert.throws(() => searchContext(records, "UTC", { startTime: "2026-09-29T08:00:00" }));
  assert.throws(() => searchContext(records, "UTC", { startHour: 12, endHour: 6 }));
  assert.throws(() => searchContext(records, "UTC", { localDate: "2026-02-30" }));
});

test("full text is searched before output truncation; sensitive rows excluded", () => {
  const long = row("long", "2026-09-29T01:00:00Z");
  long.context.screenText = "a".repeat(9000) + "hidden-tail";
  const secret = row("secret", long.timestamp); secret.context.isSensitive = true;
  const result = searchContext([long, secret], "UTC", { query: "hidden-tail" });
  assert.equal(result.totalMatches, 1);
  assert.equal(result.results[0]?.truncated, true);
  assert.equal(result.results[0]?.context.screenText?.length, 800);
});

test("protocol preserves historical records independently of recent memory", () => {
  const result = parseRequest(JSON.stringify({ version: 1, id: "history", type: "chat", payload: {
    messages: [{ role: "user", content: "今天早上看了什么帖子？" }], contextHistory: records, historyTimeZone: "Asia/Shanghai" } }));
  assert.equal(result.type, "chat");
  if (result.type === "chat") assert.equal(result.payload.contextHistory?.length, 4);
});

test("model calls search_context and receives only matching history over non-streaming HTTP", async () => {
  const requests: any[] = [];
  const server = createServer(async (req, res) => {
    if (req.url !== "/v1/chat/completions") { res.writeHead(404); res.end(); return; }
    const chunks: Buffer[] = []; for await (const c of req) chunks.push(Buffer.from(c));
    const body = JSON.parse(Buffer.concat(chunks).toString()); requests.push(body);
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ choices: [{ message: requests.length === 1
      ? { role: "assistant", tool_calls: [{ id: "search-1", type: "function", function: { name: "search_context", arguments: JSON.stringify({ localDate: "2026-09-29", startHour: 6, endHour: 12, domain: "zhihu.com" }) } }] }
      : { role: "assistant", content: "早上 09:00 阅读了知乎上的注意力帖子。" }, finish_reason: requests.length === 1 ? "tool_calls" : "stop" }], usage: { prompt_tokens: 100, completion_tokens: 30 } }));
  });
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  try {
    const result = await runChat({ purpose: "conversation", messages: [{ role: "user", content: "今天早上看了什么帖子？" }], recentMemory: [], contextHistory: records,
      historyTimeZone: "Asia/Shanghai", maxTokens: 12000, maxDurationMs: 5000 },
      { route: "cloud", provider: "openai-compatible-completions", model: "test", apiKey: "test-key", baseUrl: `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1/chat/completions` });
    assert.equal(result.usage.toolCalls, 1);
    assert.equal(requests.length, 2);
    assert.equal(requests[0].stream, false);
    assert.doesNotMatch(JSON.stringify(requests[0]), /question\/123|event-morning/);
    const tool = requests[1].messages.find((m: any) => m.role === "tool");
    assert.deepEqual(JSON.parse(tool.content).results.map((r: any) => r.id), ["morning"]);
    assert.match(result.spokenText ?? "", /09:00/);
  } finally { server.close(); await once(server, "close"); }
});

test("secret historical context is blocked before contacting the model", async () => {
  const secret = row("secret", "2026-09-29T01:00:00Z"); secret.context.contentSummary = "password: example-secret";
  await assert.rejects(runChat({ purpose: "conversation", messages: [{ role: "user", content: "history" }], recentMemory: [], contextHistory: [secret], maxTokens: 12000, maxDurationMs: 1000 },
    { route: "cloud", provider: "openai-compatible-completions", model: "test", apiKey: "test-key", baseUrl: "http://127.0.0.1:1/v1" }), /Sensitive context/);
});

test("month and open-ended date ranges expose older history independently of today's first page", () => {
  const archive = [row("july", "2026-07-21T01:00:00Z"), row("august", "2026-08-13T01:00:00Z"),
    row("september", "2026-09-09T01:00:00Z"), row("month-boundary", "2026-08-31T16:00:00Z"),
    ...Array.from({ length: 50 }, (_, i) => row(`today-${i}`, "2026-09-29T01:00:00Z"))];
  const overview = searchContext(archive, "Asia/Shanghai", { summaryOnly: true });
  assert.equal(overview.totalMatches, 54);
  assert.equal(overview.results.length, 0);
  assert.equal(overview.nextOffset, null);
  assert.deepEqual(overview.availableHistory.months, [{ month: "2026-07", count: 1 }, { month: "2026-08", count: 1 }, { month: "2026-09", count: 52 }]);
  assert.equal(searchContext(archive, "Asia/Shanghai", { month: "2026-07" }).results[0]?.id, "july");
  assert.equal(searchContext(archive, "Asia/Shanghai", { month: "2026-09", summaryOnly: true }).totalMatches, 52);
  assert.equal(searchContext(archive, "Asia/Shanghai", { startDate: "2026-07-01", endDate: "2026-09-01" }).totalMatches, 2);
  assert.equal(searchContext(archive, "Asia/Shanghai", { endDate: "2026-08-01" }).results[0]?.id, "july");
  const missing = searchContext(archive, "Asia/Shanghai", { month: "2025-01" });
  assert.equal(missing.totalMatches, 0);
  assert.equal(missing.availableHistory.count, 54);
  assert.throws(() => searchContext(archive, "UTC", { month: "2026-13" }));
  assert.throws(() => searchContext(archive, "UTC", { startDate: "2026-02-30" }));
});

test("an empty model answer after tool calls still yields grounded article evidence", async () => {
  const { answerFromRecordedContext } = await import("../src/life-agent.js");
  const answer = answerFromRecordedContext({ purpose: "conversation", messages: [{ role: "user", content: "查一下我这个月都看过哪些文章" }],
    recentMemory: [], contextHistory: [row("old", "2026-08-20T01:00:00Z"), row("new", "2026-09-20T01:00:00Z")],
    historyTimeZone: "Asia/Shanghai", maxTokens: 12000, maxDurationMs: 30000 }, new Date("2026-09-29T00:00:00Z"));
  assert.match(answer, /2026-09/);
  assert.match(answer, /zhihu.com\/question\/123/);
  assert.doesNotMatch(answer, /2026-08/);
  assert.match(answer, /模型这次没有完成文字回答/);
});

test("article fallback does not mislabel inboxes and application forms as articles", async () => {
  const { answerFromRecordedContext } = await import("../src/life-agent.js");
  const answer = answerFromRecordedContext({ purpose: "conversation", messages: [{ role: "user", content: "查一下我这个月都看过哪些文章" }],
    recentMemory: [], contextHistory: [row("post", "2026-09-20T01:00:00Z"),
      row("mail", "2026-09-21T01:00:00Z", "https://mail.google.com/mail/u/0/"),
      row("job", "2026-09-22T01:00:00Z", "https://jobs.bytedance.com/campus/position/application")],
    historyTimeZone: "Asia/Shanghai", maxTokens: 12000, maxDurationMs: 30000 }, new Date("2026-09-29T00:00:00Z"));
  assert.match(answer, /zhihu.com\/question\/123/);
  assert.doesNotMatch(answer, /mail.google.com|jobs.bytedance.com/);
});
