# Agent 历史 Context 查询

用户可以直接问 LUMA：“今天早上我在 Chrome 看过哪些知乎帖子？”模型通过 `search_context` 选择筛选条件，再根据记录回答并引用时间、URL。聊天仅暴露这个只读历史工具；主动唤醒仍受原有工具白名单控制。

## 数据流

1. Swift 从 Agent Home 已加载的全部追加式日记构建当前请求的活动快照，不局限于今天或最近 20 条。
2. 合并可见的语义补充和用户纠正，保留原始事件时间、日记 ID 和事件 ID。已隐藏活动、敏感内容和截图文件路径不进入工具快照。
3. 经本机 JSONL 传给 Pi sidecar，在本地执行筛选。快照不会整体加入模型提示词；模型只收到工具定义和命中结果。
4. OpenAI-compatible 聊天使用非流式 Chat Completions 的标准 `tools` / `tool_calls` 循环；Kimi 继续使用其原生接口。模型必须支持工具调用。离线策略模型不会自动理解自然语言历史查询。

## 参数

全部条件按 AND 组合：

| 参数 | 含义 |
| --- | --- |
| `startTime` / `endTime` | 带时区的 ISO 8601 时间，左闭右开 |
| `month` | 本机时区整月 YYYY-MM，例如 2026-07；无日期参数时查全部历史 |
| `startDate` / `endDate` | 本机时区日期范围，左闭右开；可只指定一侧 |
| `summaryOnly` | 只返回数量及按月覆盖范围，用于先发现更早记录 |
| `localDate` | 本机时区的 YYYY-MM-DD 日期 |
| `startHour` / `endHour` | 本机时区小时，左闭右开；跨午夜拆为两次查询 |
| `application` | App 名或 bundle identifier，不区分大小写的子串 |
| `domain` | 精确域名及子域名，不匹配伪装后缀 |
| `query` | 空格分隔关键词，全部匹配；支持中文子串，查标题、链接、正文等 context 字段 |
| `kind` | activity、reading、composing、researching、communicating、watching、navigating、idle |
| `tags` | 所有标签都须匹配，可查 readingProgress、opinionOutput 等行为语义 |
| `eventID` | 精确匹配事件 ID 或日记条目 ID |
| `limit` / `offset` | 默认 8 条、最多 20 条；按 nextOffset 继续翻页 |

示例（Asia/Shanghai 时区）：

```json
{
  "localDate": "2026-09-29",
  "startHour": 6,
  "endHour": 12,
  "application": "Chrome",
  "domain": "zhihu.com",
  "limit": 8
}
```

工具描述显示全部历史的起止时间和记录数量，结果中 `availableHistory` 始终表示全部历史覆盖范围，`matchingHistory` 表示筛选后的覆盖范围；第一页只有近期记录不代表更早历史不可查询。

结果包含 `results`、`totalMatches`、`nextOffset`、`timeZone`、`snapshotRecordCount` 和查询范围说明。按事件时间倒序，ID 用于同一时间的稳定排序。全文筛选发生在截断之前；较长文本返回前截断并标注 `truncated`，每页约束文本量，不能把片段当作页面全文。

## 边界

- 数据范围是请求开始时已持久化的活动。仍在聚合的活动、未采集内容不在历史工具中；当前现场仍通过现有 Context 提供。
- 空结果只代表没有匹配的已记录证据，不代表用户没有做过该活动。
- 隐藏和纠正在下一次请求快照生效。查询运行中使用固定快照以保证分页稳定。
- 云模型能看到命中的脱敏结果。页面、帖子和工具返回内容均作为不可信数据，不能作为指令。
- 当前实现对本地快照线性筛选，每次请求会在本机传输全部可见活动；历史增长后可换为索引或按需原生查询，不改变工具契约。
- 此工具已接入项目内的 Pi agent，并非对外提供的 MCP 服务。

验证覆盖时区、上午边界、组合筛选、域名误匹配、中文、分页、重启恢复、隐藏、纠正、敏感过滤，以及模型发出 tool call 后只获得命中历史的 HTTP 往返。

本地排查历史加载（仅输出数量，不输出事件正文）：

```bash
swift run AgentOnePiIntegrationHarness --context-history-summary "$HOME/Documents/AgentOne Home/Diary"
```

更新后须运行新构建的应用；仅生成 ZIP 不会替换 Applications 下正在运行的旧版本。

## 连接诊断

API Key 设置中的测试通过与聊天相同的 Pi sidecar 发起请求，并要求模型调用一次 `search_context` 后回复。测试使用空记录，不发送真实历史；只有完成工具调用且没有超时才显示成功。基础服务地址与完整 `/chat/completions` 地址均可填写，不会重复追加路径。

聊天使用独立的 sidecar 进程。回车 Context 分析、日记维护和后台提醒的取消或重启不会中断交互聊天；聊天完成后释放任务槽，取消操作按请求 ID 隔离。
