# 0.2.7：Agent 连接设置与自动地点

## STATUS

已安装 0.2.7 并验证原生设置页、MCP 模式、自检与 UI 插件导出。真机系统“定位服务”总开关关闭，AgentOne 显示未获允许；开启系统总开关与仅授予 AgentOne 的确认已向用户提出，未在未确认时更改。实际定位成功尚待授权后验证。

## DECISIONS

用户要求设置内连接 Agent，推荐插件，同时支持 MCP；地点不再手填，自动调用定位。

- 插件以 [OpenAI 官方打包格式](https://developers.openai.com/plugins/build/plugins) 与 [本机 stdio 说明](https://developers.openai.com/plugins/deploy/desktop-only) 为依据：portable manifest、Codex 兼容层、MCP 与一个聚焦的回忆/分析 skill。无 lifecycle hook、独立 Agent runtime、自动发布或宿主配置篡改。
- 插件生成在本机 Application Support，包含源码与路径配置，不复制用户 Memory 数据或凭据。导入仍由支持本机插件的宿主完成；自检与真实宿主最近连接分开显示。
- 地点用 Apple Core Location，Info.plist 提供 macOS 定位用途说明；只在系统允许后获取。每约 3 分钟做一次单次定位，录音/监听暂停时同步暂停定位，关闭偏好后停止并清空当前缓存。
- 不用 IP 或 Wi-Fi 名猜地点。位置超过 10 分钟、误差大于 5 公里或坐标无效时不填。可读地址随精度降为街道、区域或城市；保留原始精度和采样时间。系统定位不能确认工位/室内房间。
- 段内首次获得的定位可以作为该段提示，但明确记录 sampled_during_segment；段结束之后的位置不倒填。历史手动地点与引用不改写。

## CHANGES

- 设置页新增插件/MCP 切换、生成插件、复制接入说明、复制配置、真实进程自检与最近宿主握手。
- 记录页改只读自动地点；设置页增加自动地点开关、授权/刷新、定位设置入口和真实状态。
- context_json 增加定位来源、经纬度、误差半径和时间；无 schema 迁移。
- MCP 初始化记录宿主自报名称、版本和时间，忽略本机自检对最近宿主状态的覆盖。
- 126 个 Swift 测试、20 个 MCP 测试通过；新增插件迁移目录后真实握手且不复制用户数据、位置有效性/过期与 AAC 时段定位证据测试。skill-creator 校验通过。

## TESTS / HANDOFF

本机插件不等于任意宿主已安装，最近握手不等于持续在线。Core Location 真机结果与系统权限须单独记录，不能用合成坐标冒充实际授权或成功定位。

## DEVICE VALIDATION

- 设置默认选择插件；切换 MCP 出现复制配置入口，验证后恢复插件推荐。
- 原生“检查服务”真实启动包内 MCP，返回 9 个工具；仍显示“尚未收到 Agent 连接”，没有用自检冒充已连接。
- 从 UI 生成的插件实际包含两类 manifest、工作流、可重定位启动配置及本地 marketplace；用隔离测试目录启动返回 9 个工具，未复制用户数据库或原音。未擅自安装到全局 Agent 配置。
- macOS 系统设置读取确认总开关 off、AgentOne 开关不可用；没有开启其他应用定位，也没有用测试坐标替代真实设备位置。
