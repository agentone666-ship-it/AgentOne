import { createInterface } from 'node:readline';
import { readFileSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

const referenceEpochMs = 978307200000;
const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
const unsafe = /(?:api[_ -]?key|bearer\s+[\w.-]+|password\s*[:=]|sk-[A-Za-z0-9_-]{12,})/i;

function diaryPath() {
  if (process.env.AGENTONE_DIARY_DIR) return process.env.AGENTONE_DIARY_DIR;
  try {
    const root = execFileSync('/usr/bin/defaults', ['read', 'life.agentone.desktop', 'agentOne.home.rootPath'], { encoding: 'utf8', timeout: 1000, stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    if (root) return join(root.replace(/^~/, homedir()), 'Diary');
  } catch {}
  return join(homedir(), 'Documents', 'AgentOne Home', 'Diary');
}

function dateOf(value) {
  if (typeof value === 'number') return new Date(referenceEpochMs + value * 1000);
  return new Date(value);
}

function loadRecords() {
  const directory = join(diaryPath(), 'Daily');
  let files;
  try { files = readdirSync(directory).filter(name => /^\d{4}-\d{2}-\d{2}\.md$/.test(name)).sort(); }
  catch { return []; }
  const entries = [];
  for (const file of files) {
    const data = readFileSync(join(directory, file), 'utf8');
    for (const match of data.matchAll(/<!-- agentone-json: ([A-Za-z0-9+/=]+) -->/g)) {
      try { entries.push(JSON.parse(Buffer.from(match[1], 'base64').toString('utf8'))); } catch {}
    }
  }
  const hidden = new Set();
  const enrichmentByEntry = new Map(), enrichmentByEvent = new Map();
  for (const entry of entries) {
    const change = entry.payload?.visibilityChanged?._0;
    if (change) (change.isHidden ? hidden.add : hidden.delete).call(hidden, change.targetEntryID);
  }
  for (const entry of entries) {
    if (hidden.has(entry.id)) continue;
    const value = entry.payload?.contextEnrichment?._0;
    if (value) {
      if (value.targetActivityEntryID) enrichmentByEntry.set(value.targetActivityEntryID, value);
      if (value.targetEventID) enrichmentByEvent.set(value.targetEventID, value);
    }
  }
  return entries.flatMap(entry => {
    if (hidden.has(entry.id)) return [];
    const activity = entry.payload?.activity?._0;
    if (!activity) return [];
    const event = activity.event ?? {};
    const enrichment = enrichmentByEntry.get(entry.id) ?? enrichmentByEvent.get(event.id);
    const context = enrichment?.context ?? activity.session?.context ?? event.context ?? {};
    if (context.isSensitive || event.context?.isSensitive) return [];
    const title = context.windowTitle ?? enrichment?.activityTitle ?? null;
    const url = context.url ?? null;
    const summary = [context.contentSummary, enrichment?.summary, activity.narrative].filter(Boolean).join('\n').slice(0, 500);
    if (unsafe.test([title, url, summary].join(' '))) return [];
    const timestamp = dateOf(event.timestamp ?? entry.timestamp);
    if (!Number.isFinite(timestamp.getTime())) return [];
    return [{ id: entry.id, eventID: event.id, timestamp: timestamp.toISOString(),
      kind: activity.session?.kind ?? 'activity', application: context.applicationName ?? null,
      bundleIdentifier: context.bundleIdentifier ?? null, title, url, summary,
      tags: [...new Set([...(context.semanticTags ?? []), ...(event.semantics ?? [])])] }];
  });
}

const dateFormatter = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', hourCycle: 'h23' });
function localParts(iso) {
  const parts = Object.fromEntries(dateFormatter.formatToParts(new Date(iso)).map(part => [part.type, part.value]));
  return { date: `${parts.year}-${parts.month}-${parts.day}`, hour: Number(parts.hour) };
}
function coverage(records) {
  const months = {};
  for (const record of records) {
    const month = localParts(record.timestamp).date.slice(0, 7);
    months[month] = (months[month] ?? 0) + 1;
  }
  return { count: records.length, earliest: records.at(0)?.timestamp ?? null,
    latest: records.at(-1)?.timestamp ?? null, months };
}
function search(args = {}) {
  const records = loadRecords().sort((a, b) => a.timestamp.localeCompare(b.timestamp));
  const all = coverage(records);
  const terms = (args.query ?? '').toLowerCase().split(/\s+/).filter(Boolean);
  const matched = records.filter(record => {
    const { date, hour } = localParts(record.timestamp);
    if (args.month && !date.startsWith(args.month)) return false;
    if (args.localDate && date !== args.localDate) return false;
    if (args.startDate && date < args.startDate) return false;
    if (args.endDate && date >= args.endDate) return false;
    if (args.startHour !== undefined && hour < args.startHour) return false;
    if (args.endHour !== undefined && hour >= args.endHour) return false;
    if (args.application && !`${record.application ?? ''} ${record.bundleIdentifier ?? ''}`.toLowerCase().includes(args.application.toLowerCase())) return false;
    if (args.kind && record.kind !== args.kind) return false;
    if (args.domain) {
      try { const host = new URL(record.url).hostname.toLowerCase(); const domain = args.domain.toLowerCase(); if (host !== domain && !host.endsWith(`.${domain}`)) return false; }
      catch { return false; }
    }
    if (args.tags?.some(tag => !record.tags.some(value => value.toLowerCase() === tag.toLowerCase()))) return false;
    const searchable = `${record.title ?? ''} ${record.url ?? ''} ${record.summary} ${record.tags.join(' ')}`.toLowerCase();
    return terms.every(term => searchable.includes(term));
  });
  const offset = args.offset ?? 0, limit = args.limit ?? 20;
  return { timeZone, availableHistory: all, matchingHistory: coverage(matched), totalMatches: matched.length,
    results: args.summaryOnly ? [] : matched.reverse().slice(offset, offset + limit),
    nextOffset: !args.summaryOnly && offset + limit < matched.length ? offset + limit : null,
    note: 'These are recorded activity events, not a complete browsing history. URLs alone do not prove an article was read.' };
}

const tools = [{
  name: 'search_context',
  description: 'Search local AgentOne personal Context across all available history. Filters combine with AND. Use summaryOnly to discover months; then query a month or date range. This is read-only and does not contact a cloud service.',
  inputSchema: { type: 'object', additionalProperties: false, properties: {
    month: { type: 'string', description: 'Local YYYY-MM' }, localDate: { type: 'string', description: 'Local YYYY-MM-DD' },
    startDate: { type: 'string', description: 'Inclusive local YYYY-MM-DD' }, endDate: { type: 'string', description: 'Exclusive local YYYY-MM-DD' },
    startHour: { type: 'integer', minimum: 0, maximum: 23 }, endHour: { type: 'integer', minimum: 1, maximum: 24 },
    application: { type: 'string' }, domain: { type: 'string' }, kind: { type: 'string' }, query: { type: 'string' },
    tags: { type: 'array', items: { type: 'string' } }, summaryOnly: { type: 'boolean' },
    limit: { type: 'integer', minimum: 1, maximum: 50 }, offset: { type: 'integer', minimum: 0 }
  } }
}];

function reply(id, result) { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result }) + '\n'); }
const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', line => {
  let request;
  try { request = JSON.parse(line); } catch { return; }
  if (request.id === undefined) return;
  try {
    if (request.method === 'initialize') reply(request.id, { protocolVersion: '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: 'personal-context-memory', version: '0.1.0' } });
    else if (request.method === 'tools/list') reply(request.id, { tools });
    else if (request.method === 'tools/call') {
      if (request.params?.name !== 'search_context') throw new Error('Unknown tool');
      reply(request.id, { content: [{ type: 'text', text: JSON.stringify(search(request.params.arguments)) }] });
    } else reply(request.id, {});
  } catch (error) { reply(request.id, { content: [{ type: 'text', text: String(error.message ?? error) }], isError: true }); }
});
