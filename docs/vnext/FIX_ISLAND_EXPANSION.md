# 灵动岛展开问题修复（0.2.1）

## STATUS

- 用户反馈：灵动岛不会展开。
- 实查正在运行的 `~/Applications/AgentOne.app` 是 0.1.0，仍显示旧 LUMA 主窗口并携带 Pi Runtime；不是新灵动岛安装包。
- 已将本机应用更新为 0.2.1，并保留旧 App bundle 备份；没有删除旧 Diary 或凭证文件。
- 新版当前保持展开，系统音/麦克风录音、本机 ASR、原音导出与登录自动续录均未在本轮开启。

## DECISIONS / CHANGES

- 提取 IslandWindowController：由普通 NSView 承载 NSHostingView，关闭 hostingView 的自动 sizingOptions，使用四边约束让 AppKit 掌握实际窗口尺寸。
- 展开/收起沿同一顶部锚点切换为 420×560 / 240×42；菜单展开显式 show/orderFront，不依赖 expanded 重复赋值触发。
- 固定面板 darkAqua 外观，修复实际浅色 macOS 环境中黑色胶囊上的文字也变黑的问题。
- 产品版本提升为 0.2.1；更新包重新签名并通过 ZIP 自检。

## TESTS

- 新增真实 NSPanel 回归：反复切换展开/收起 6 次，等待 SwiftUI 布局后检查窗口、contentView 尺寸和顶部锚点；通过。
- 检查面板 darkAqua 外观；通过。
- 隐藏后调用 show(expanded:true)，确认可见和展开宽度；通过。
- 最终 ZIP 的签名、版本、资源与真实 MCP 子进程检查通过。
- 更新本机实际 App 后，通过 CUA 点击胶囊收起，再通过鼠标坐标点击胶囊展开；AX 中重新出现录音、地点、回忆与控制项。
- 实际收起界面的文字和箭头已恢复白色对比；不是只看静态渲染图。

本次不证明真实录音或 ASR 效果，也没有借测试启动这些能力。云端结果以 PR #2 最新 Checks 为准。

## HANDOFF

- 本机路径仍为 `~/Applications/AgentOne.app`，无需用户重新定位应用。
- 旧 0.1.0 bundle 备份在 `~/Library/Application Support/AgentOne/Backups/AgentOne-0.1.0-4a60109f.app`。
- 点击胶囊或右侧箭头可切换展开/收起。需要录音时由用户在展开区明确开启。
