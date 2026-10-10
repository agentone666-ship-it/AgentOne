import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = mkdtempSync(join(tmpdir(), 'personal-context-memory-'));
const daily = join(root, 'Daily');
mkdirSync(daily);
const epoch = 978307200000;
const entry = (id, date, url, sensitive = false) => ({
  id, timestamp: (Date.parse(date) - epoch) / 1000,
  payload: { activity: { _0: { narrative: '阅读网页', event: {
    id: `event-${id}`, timestamp: (Date.parse(date) - epoch) / 1000, semantics: ['readingProgress'],
    context: { applicationName: 'Chrome', bundleIdentifier: 'com.google.Chrome',
      windowTitle: '一篇文章', url, isSensitive: sensitive, semanticTags: ['readingProgress'] }
  }, session: { kind: 'reading', context: { applicationName: 'Chrome', url, windowTitle: '一篇文章', isSensitive: sensitive, semanticTags: ['readingProgress'] } } } } }
});
const rows = [entry('july', '2026-07-20T01:00:00Z', 'https://example.com/posts/july'),
  entry('september', '2026-09-20T01:00:00Z', 'https://example.com/posts/september'),
  entry('secret', '2026-09-21T01:00:00Z', 'https://example.com/posts/secret', true)];
for (const row of rows) {
  const day = new Date(epoch + row.timestamp * 1000).toISOString().slice(0, 10);
  writeFileSync(join(daily, `${day}.md`), `<!-- agentone-json: ${Buffer.from(JSON.stringify(row)).toString('base64')} -->\n`);
}
const server = spawn(process.execPath, [fileURLToPath(new URL('./server.mjs', import.meta.url))],
  { env: { ...process.env, AGENTONE_DIARY_DIR: root }, stdio: ['pipe', 'pipe', 'pipe'] });
const send = (id, method, params) => server.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
const replies = [];
server.stdout.setEncoding('utf8');
let buffer = '';
server.stdout.on('data', chunk => {
  buffer += chunk;
  while (buffer.includes('\n')) {
    const index = buffer.indexOf('\n');
    replies.push(JSON.parse(buffer.slice(0, index)));
    buffer = buffer.slice(index + 1);
  }
});
send(1, 'initialize', {});
send(2, 'tools/list', {});
send(3, 'tools/call', { name: 'search_context', arguments: { month: '2026-07', domain: 'example.com' } });
send(4, 'tools/call', { name: 'search_context', arguments: { month: '2026-09', summaryOnly: true } });
await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('MCP server timed out')), 5000);
  const check = setInterval(() => { if (replies.length === 4) { clearTimeout(timer); clearInterval(check); resolve(); } }, 10);
});
try {
  assert.equal(replies[0].result.serverInfo.name, 'personal-context-memory');
  assert.deepEqual(replies[1].result.tools.map(tool => tool.name), ['search_context']);
  const july = JSON.parse(replies[2].result.content[0].text);
  assert.equal(july.totalMatches, 1);
  assert.equal(july.results[0].url, 'https://example.com/posts/july');
  assert.equal(july.availableHistory.count, 2);
  const september = JSON.parse(replies[3].result.content[0].text);
  assert.equal(september.totalMatches, 1);
  assert.deepEqual(september.results, []);
  console.log('MCP install protocol and cross-month search passed');
} finally {
  server.kill();
  rmSync(root, { recursive: true, force: true });
}
