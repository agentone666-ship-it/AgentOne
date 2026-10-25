# AgentOne v0.2：实现状态与交接

2026-10-25。状态：本地组件与接口已验证，可进入真实设备验收；不是全天录音或模型效果已验收。

## STATUS

- 用户已确认：系统声音＋麦克风独立保存，保留对齐时间；先接通用 MCP，具体宿主后定。
- 实现分支：`codex/audio-memory-mvp`，基于原 CI/CD PR 和独立设计提交。
- 默认 `AgentOne` 已切换为原生灵动岛采集 App；历史原型通过 `AgentOneLegacy` 显式运行。
- 本轮没有开启真实系统音、麦克风、定位或云模型。没有安装特定 MCP 宿主、创建发布标签或公开发布。
- 本地验证快照见 TESTS；云端状态以本分支 PR 的最新 Checks 为准，不复用 PR #1 的绿色作为本功能证据。

## DECISIONS

1. 保留必要的有 macOS 权限的采集进程；删除新默认产物对 Pi Agent Loop、独立聊天、模型路由和 OAuth 的依赖。
2. 系统音和麦克风分别编码为 AAC/m4a，默认约 60 秒轮转。AAC 是有损编码，不宣传无损原件。
3. 两轨保留原始 PTS，共享 host/wall-clock 锚点；非 host-clock 时间戳标记为 arrival_estimate，不宣称完成实机时钟校准。
4. 本机 Speech 仅使用 on-device 识别。不可用时排队，绝不静默回退到云端 Speech。
5. 静默语义分析由宿主调度 MCP。通用 MCP 本身不保证关闭的宿主仍在运行或推理。
6. 长期记忆由宿主把证据巩固后写回，不在采集进程内再造一个规划/行动智能体。
7. 不按重要性或年龄自动删除原音；真实磁盘与能耗数据尚未测量。当前名义编码合计约 144 kbit/s，全天约 1.56 GB 是估算而非实测。

## CHANGES

### 原生入口与数据面

- `AgentOneCaptureApp`：顶部 NSPanel、状态、手动启停、地点标注、回忆搜索、原音回放、最近片段删除。
- 首次启动不录音。登录自动续录需另行开启；手动暂停持久保存，不因重启自动取消。
- 录音获授权后的后续启动默认收起，避免每天展开大窗口。错误有独立状态。
- 锁屏和休眠分别跟踪；启用锁屏暂停时，唤醒不能绕过仍未解除的锁屏状态。锁屏暂停默认开启，可关闭以尽量持续记录；系统能否继续供流仍需设备实测。
- 退出先停止采集并封口，重复停止请求等待同一次封口，避免提前释放录音锁；关闭后迟到的回调不能重新打开文件，启动失败会清理录制状态。
- `AudioCaptureService`：ScreenCaptureKit 双路输出；不注册屏幕画面输出，不保存连续视频。
- `AudioTrackWriter`：真实 CMSampleBuffer → PCM → AAC，分轨、时间、哈希、格式/断流轮转；未封口尾段标为 incomplete。
- 文件/数据库使用本机私有权限，不等同于应用级加密。单采集者进程锁防止两个采集进程争用同一目录。

### 资料、队列与长期 Memory

- Swift 与 Node 共享 SQLite schema，跨进程 WAL/busy timeout；同一个库供原生 App 和 MCP 使用。
- 保存：录音开始/结束、当时时区、来源、PTS、时钟映射、采样率、声道、音频哈希、手动地点、片段开始时的前台应用线索。
- `get_capture_status`、`search_memory`、`get_memory_evidence`、`claim_analysis_jobs`、`submit_memory_analysis`、`retain_memory` 共 6 个工具。
- 转写和分析分两个任务阶段，原子 lease、过期、内容哈希、转写版本和结果幂等性防止陈旧写回。
- 每项事实/决定/待办候选都带音频范围与原话；检查引用对应的转写区间，仍不等于理解正确。
- `retain_memory` 支持项目摘要、实体线索、决定、未解决事项，引用多个片段、记录有效时间与得知时间、保留被替代版本。
- `search_memory` 联合返回原始片段与巩固记忆；支持关键词变体、日期、来源、软地点提示、分页和旧版本。
- memory 的 active/superseded 是索引版本状态，不是“当前世界事实一定成立”；宿主仍须检查 valid_from/valid_until 与证据。
- 删除来源会清除原音/转写/标签，使依赖的长期记忆失效，拒绝未完成任务写回；已被替代的旧事实不会自动复活。
- 原音的 MCP resource 默认关闭，需用户在原生 UI 明确开启。MCP 没有开始录音和通用行动工具。

### 分发与门禁

- 根目录 VERSION 为新产品版本；历史 Pi package.json 仅为历史回归包版本。
- 默认 ZIP 仅拷贝 CaptureKit 的 schema resource 和通用 MCP 的服务文件，不携带旧 Pi Sidecar 或聊天资源。
- 新主产物的依赖图为 `AgentOneCaptureApp → AgentOneCaptureKit`，不依赖旧 AgentOneApp/Core/ModelAuth/PiRuntime。
- CI 保留历史回归，新增 Native Audio Harness、双进程 MCP 队列竞争、Swift↔SQLite↔MCP、长期记忆与新 ZIP 黑盒检查。
- `.gitignore` 增加 Audio、SQLite/WAL 和录音锁，避免自定义 Memory 根目录时误提交原音或数据库。

## TESTS

本地 macOS / Swift 6.1.2 / Node 22.22.1：

- `bash scripts/ci.sh all`：通过。旧 TypeScript 56 项，通用 MCP 9 项，Swift 98 项（包含历史回归）。
- 新 Native Audio Harness：构造真正的 CMSampleBuffer，经过生产音频读取、编码和封口路径，双路输出 4 个可读 AAC 片段；分轨、轮转、共享时间戳、哈希、待转写任务通过。
- Swift 原生编码写出的 SQLite 库，经真实 MCP 子进程领取、合成转写、引用标签和长期巩固后，可历史查询并取回证据。
- 两个真实 MCP 子进程争用同一个队列，没有重复领取；过期 lease、错误 token、变更音频、伪造引用与删除后写回均被拒绝。
- 长期记忆更新后旧版本仍可查询；删除来源失效派生内容，不使旧结论重新生效。
- 最终 ZIP：签名严格检查、原生 `--self-check`、版本/权限描述、模块符号无 Pi/ModelAuth、包内真实 MCP 进程启动和工具调用：通过。
- 原生 App 在独立临时目录的演示态启动、渲染与退出：通过；没有请求录音权限，截图仅来自自身 NSView。
- actionlint、Bash/Zsh 语法和 `git diff --check`：通过。

首轮云端 CI：[40195106835](https://github.com/agentone666-ship-it/AgentOne/actions/runs/40195106835) 全部成功；对应首个实现提交 `55aee7b`。后续生命周期修正的最终结果以 [PR #2 Checks](https://github.com/agentone666-ship-it/AgentOne/pull/2/checks) 为准。

### 这些检查不能证明什么

- 合成音频是音调，不是实际电脑声音。合成转写/标签是协议 fixture，不是本机 ASR 或真实模型输出。
- 没有执行真正的系统权限授权、双设备采集或连续一整天的记录。
- 未验证中文多人对话、人名、说话人识别、时钟偏差、输入/输出设备切换与睡眠唤醒的实机表现。
- 旧 Swift 的 live foreground opt-in 测试没有真实会话参数，不计为真实前台验收。

## 限制与待验收

- **真实设备验收**：系统音＋麦克风短录、各轨回放、权限撤销、休眠/锁屏、蓝牙/输入输出设备切换、午夜/时区/手动校时和全天资源占用。
- **模型验收**：本机语言资源是否可用、ASR 准确度、标签和人物/待办提取效果、队列吞吐和宿主实际调度。
- **长期检索**：当前为词面检索＋宿主扩展＋结构化巩固；没有 embedding、向量重排、自动实体图谱或跨片段 episode 自动合并。
- **信息采集**：地点目前手动；未采 GPS、声纹、实际发声应用归因、输入/输出设备 UID、完整窗口/网页/OCR Context。旧日记插件与数据保留，尚未合并进新音频索引。
- **数据控制**：应用级加密、可视化容量配额、按应用排除和批量保留管理未实现；不能承诺敏感原声在识别前永不落盘。
- **发行**：仍为 ad-hoc 签名，没有 Apple 公证、正式升级通道或公开 release。

## HANDOFF

1. 运行 `./scripts/build_app.sh release`，将 ZIP 解压到普通本地目录后启动；首次启动只显示入口。
2. 用户自己在岛上点击“开启录音”，授予系统音与麦克风权限，先录一段可核验内容再暂停、分别回放。
3. 根据需要显式启用本机转写。不可用时任务仍保留，不上传原音。
4. 运行 `node scripts/print_mcp_config.mjs '/path/to/AgentOne.app'`，按任意宿主的 MCP 说明接入。
5. 宿主支持后台任务时调度 analyze_pending_audio；否则只能在宿主运行时处理。真实待办执行仍由宿主获得当前授权后完成。
6. 如需让宿主读取原音，另行开启岛上的原音访问；宿主可能将资料交给云模型。

已完成的是可运行的采集/插件开发预览与接口验证。设备日常使用和模型效果的最终验收须另行记录。
