# Personal Context Memory

This Codex plugin exposes one read-only MCP tool, `search_context`, over the local AgentOne diary. It reads the append-only `Diary/Daily/*.md` files on each call, so new captured events become searchable without exporting or synchronizing another database. The tool does not make network requests.

It supports all recorded months, a date or date range, local hours, app, domain, activity kind, tags, keyword, pagination, and summary-only coverage. Results are recorded evidence rather than proof of every visit or article read. Hidden entries and entries marked sensitive are excluded.

The collector and diary storage remain in AgentOne. This plugin contains only retrieval; companion chat, avatar, proactive reminders, digest generation, and cloud model configuration are outside its scope. Removing those from the desktop collector is a separate migration because the current app still owns capture and diary writes.

Set `AGENTONE_DIARY_DIR` to point to a different diary directory when testing. Otherwise the tool uses AgentOne's configured Home or `~/Documents/AgentOne Home/Diary`.

Run `node test.mjs` to verify MCP protocol and cross-month retrieval.
