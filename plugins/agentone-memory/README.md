# AgentOne Memory：通用 MCP

Node.js 22.19+。不绑定 Codex、DeepSeek 或其他宿主，不包含 Agent Runtime。

## 运行

```bash
node plugins/agentone-memory/server.mjs
```

默认读取 `~/Documents/AgentOne Home/Memory`；macOS 上会使用 AgentOne 已保存的 Agent Home 设置。
自定义目录设置 `AGENTONE_MEMORY_HOME`，它是 Memory 目录本身，不是 Diary 或 Agent Home 的父目录。

```bash
AGENTONE_MEMORY_HOME='/absolute/path/to/Memory' node plugins/agentone-memory/server.mjs
node scripts/print_mcp_config.mjs
# 或生成指向解压后安装包的配置：
node scripts/print_mcp_config.mjs '/Applications/AgentOne.app'
```

生成的是常见 `mcpServers` 配置结构，按宿主的 MCP 配置说明放置；不自动修改或启动任何宿主。
Node 路径和服务器路径使用实际绝对路径，避免依赖宿主启动时的工作目录与 PATH。
原生 App 的打包资源中也包含本服务，位置为 `Contents/Resources/agentone-memory/`。

## 工具与后台处理

- `get_capture_status`：采集心跳、双轨历史、未完成尾段、缺口和任务状态。
- `search_memory`：检索跨月转写与标签，可传多个短关键词变体；地点提示默认只排序。
- `retain_memory`：将一段或多段证据巩固为长期摘要/决定/未解决事项，保存有效时间、得知时间、替代关系。
- `get_memory_evidence`：取带偏移的原文、分析版本和音频 URI。
- `claim_analysis_jobs`：按 stage 领取转写或标签任务，最多 3 项，带 lease 和内容哈希。
- `submit_memory_analysis`：回写有来源的转写 / 标签 / 事实候选，或归还失败任务。

`analyze_pending_audio` prompt 提供一次有界分析流程。宿主需要自行支持后台调度，定时调用此 prompt / 工具；
仅安装 MCP 不会让一个关闭的宿主自动推理。本机 ASR 已启用且支持离线识别时，会持续处理待转写片段；
不能本机识别的任务保留在队列中，不静默改用云服务。

分析输出的每条事实 / 决定 / 待办都必须带原话和音频区间，
服务器检查范围、原话是否出现在该区间的转写中、source hash、lease 和转写版本。
这能校验证据引用，不能证明 ASR 内容与模型理解一定正确。
长期记忆的 active/superseded 是版本状态；宿主还需结合 valid_from/valid_until 判断当时是否有效。
检索 from/to 限制的是证据录制时间，不能替代对事实有效时间的判断。
任务候选与实际执行分离，不提供发送、浏览器控制或任意 shell 工具。

## 原音访问与数据控制

默认只提供文字资料与 `agentone://audio/<segment-id>` 引用。
`resources/read` 读取原音前，用户必须在原生灵动岛明确开启“允许 MCP 读取原音”。
宿主可能会将读取的文字或原音交给它的云模型；该设置不是端到端防外发保证。
服务自身不调用网络 API，也不会主动上传音频。

采集只由原生 UI 明确开启，MCP 没有启动录音工具。
本机 UI 的删除会移除片段、转写、标签和派生记录，并拒绝仍在运行的旧任务写回。
已经被宿主读取或导出的副本无法自动收回；SQLite 删除也不等同于 SSD/备份的取证级擦除。

## 当前检索边界

已实现：原文 / 标签 / 长期记忆关键词、查询扩展、日期范围、分轨过滤、软地点提示、分页、证据版本，以及宿主驱动的跨段巩固与历史替代关系。
SQLite 元数据与查询不会只读取最近一天，因此旧记录仍可查询。
尚未实现：embedding、向量重排、跨片段 episode 自动合并、实体图谱检索；宿主没有后台调度时也不会自行巩固。
宿主可在一次任务中分步查询、读取多份证据并整合，但不能把这些能力宣传成已内置的长期语义记忆。

旧 `personal-context-memory` 插件与 Diary 数据保留；本服务目前检索新音频库，不会迁移或删除旧日记。
