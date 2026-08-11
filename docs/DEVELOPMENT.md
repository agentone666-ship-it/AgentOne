# AgentOne 开发指南

## 环境

- macOS 14+
- Swift 6.1+
- Node.js 22.19+
- npm
- Deno

确认工具链：

```bash
swift --version
node --version
npm --version
deno --version
```

## 安装

```bash
git clone <repository-url>
cd AgentOne/AgentOneLifeRuntime
npm ci
cd ..
```

## 常用命令

Swift 构建与单测：

```bash
swift build
swift test
```

TypeScript Sidecar：

```bash
cd AgentOneLifeRuntime
npm run build
npm test
```

完整接口级 E2E：

```bash
./scripts/test_e2e.sh
```

生成 Release App：

```bash
./scripts/build_app.sh release
```

## 模型配置

应用支持 Kimi device OAuth 和 OpenAI-compatible API。模型地址、模型名与用户凭证由应用设置管理，不应硬编码到新功能、测试或提交中。

测试模型接口时使用本地 URLProtocol/localhost fixture 和明显的假凭证。任何测试都不应依赖真实用户 API Key。

## 代码边界

- 高频采集、系统权限和 AppKit 放在 `AgentOneApp/SystemIntegration`。
- 可确定测试的业务规则放在 `AgentOneCore`。
- 模型接口和结果解析放在 `AgentOneApp/ModelRuntime`。
- Pi 协议和 Swift 进程桥放在 `AgentOneApp/PiRuntime`。
- Sidecar 工具、预算和 provider 路由放在 `AgentOneLifeRuntime`。
- SwiftUI View 不直接读取日记文件或执行模型请求；通过 Runtime/ViewModel 接收投影。

## Context 变更的测试要求

涉及 Hook、OCR、Activity Session、意图或日记时，至少验证：

1. 高频重复信号不会生成重复语义记录。
2. 状态开始、延续、切换和结束的边界。
3. 回车只生成一次关键提交证据。
4. 中文输入法未提交拼音与已提交文字的协调。
5. 密码、支付、验证码和 API Key 永远被拦截。
6. 模型失败不会把日记伪装成已分析。
7. 重启后 Replay、Memory 和 Skill 投影一致。

仅验证“应用能启动”不足以合并 Context 链路变更。优先补接口级或真实进程边界测试。

## 文档截图模式

仓库提供只读的脱敏演示模式，用于生成 README 截图：

```bash
# 先解压 ./scripts/build_app.sh 生成的 build/AgentOne.app.zip，
# 再直接启动可执行文件，确保演示环境变量传入应用进程。
AGENTONE_DOCUMENTATION_DEMO=1 \
AGENTONE_DOCUMENTATION_SECTION=now \
/path/to/AgentOne.app/Contents/MacOS/AgentOne
```

可选 section：`now`、`replay`、`memory`、`journal`、`skills`、`settings`。演示模式不启动全局监听、不读取 Agent Home，也不调用模型。

## 提交前

```bash
./scripts/test_e2e.sh
git diff --check
git status --short
```

然后执行 `docs/PRIVACY.md` 的敏感信息和截图检查。
