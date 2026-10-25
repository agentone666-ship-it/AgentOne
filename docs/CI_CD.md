# GitHub 开发、验证与发布

## 日常开发

从最新 `main` 建立 `codex/<topic>` 或其他主题分支，通过 PR 合入。
提交说明采用 Conventional Commits；一个 PR 聚焦一个可解释的行为变化。
PR 中写清输入、预期结果、验证证据和仍需人工验收的部分。

本地与 Actions 使用同一测试入口：

```bash
npm ci --prefix AgentOneLifeRuntime
bash scripts/ci.sh all
```

也可以单独执行 `runtime`、`swift`、`integration`、`package`。
`npm test` 会先构建生产 Sidecar，保证从干净 checkout 运行真实 JSONL 进程测试。
Node 本地版本见 `.nvmrc`，Deno 见 `.deno-version`；macOS CI 固定 Xcode 16.4 / Swift 6.1。

## 自动化门禁

`CI` 在每个 PR、main push 和手动触发时运行，也供发布流程复用。
不设置路径过滤，避免 required check 因文档 PR 没有被触发而永久等待。

| 检查 | 验证内容 | 环境 |
| --- | --- | --- |
| Workflow lint | actionlint、共享 Bash 入口语法 | Ubuntu |
| Runtime | 生产构建、TS 单测、JSONL 子进程、localhost 模型协议、Memory MCP 跨月检索 | Node 22.19（支持下限）与 Node 24 |
| Dependency audit | 已知 high/critical 生产依赖问题阻断 | Node 24 |
| macOS tests and package | Swift 单测、合成图像 OCR、5 个 Harness、Release 打包、签名与内嵌 Sidecar 黑盒 E2E | macOS 15 / arm64 |
| all checks passed | 所有上述检查必须成功，失败或跳过都不能变绿 | Ubuntu |

Actions 默认只有 `contents: read`；checkout 不保留 Git 凭证。
测试只使用合成数据、临时目录、假密钥、URLProtocol 和 localhost 服务。
普通 CI 不需要真实模型密钥，也不执行真实 OAuth 登录或全局桌面采集。
超时限制任务时长，新提交取消同 ref 的旧 CI。

日志保留 7 天。验证成功的 `AgentOne-macos-arm64` artifact 内含
`AgentOne.app.zip` 和 `SHA256SUMS`，保留 14 天。
不上传 Agent Home、日记、截图目录或整个工作区。
Dependabot 每周检查 Actions 和 npm 依赖；Pi 两个包成组升级后仍需完整门禁。

## main 保护与仓库设置

维护者应把 `all checks passed` 设为 main 的 required status check，要求分支跟上 main。
要求 PR、线性提交历史、解决所有讨论，禁用强推与删除 main。
单维护者阶段不要求自己的 PR 获得自己的批准；CODEOWNERS 负责明确归属，
团队增加后再要求至少一位其他维护者 review。
推荐只保留 squash merge，并在合并后删除主题分支。

这些是 GitHub 服务端设置；不能仅靠本地 YAML 声称已生效。
实际应用状态和云端验证证据见 [本次落地记录](GITHUB_STANDARDIZATION.md)。

## 预发布流程

1. 更新 `AgentOneLifeRuntime/package.json` 和锁文件中的版本，通过 PR 合入 main。
   `build_app.sh` 自动将产品版本写入 `CFBundleShortVersionString`；构建号可通过
   `AGENTONE_BUILD_NUMBER` 设置，默认 `1`。
2. 维护者在 main 的目标提交上创建并推送 `vX.Y.Z` 标签。
3. 在 Actions 选择 `Release preview`，选择该 tag，手动执行。
4. 流程检查 tag 与 package.json 版本一致、提交属于 main，然后重新运行完整 CI。
5. 发布任务只下载该次 CI 已验证的 ZIP，并核对 SHA256；不再次构建。
   仅该任务具有 `contents: write`，并通过 `release-preview` environment。
6. 生成 **draft + prerelease**。维护者检查后决定是否公开；不会自动覆盖已有 release。

该流程目前用于开发预览：安装包为 ad-hoc 签名，尚未配置 Developer ID、
Apple 公证、正式更新通道或面向用户的自动升级。不要把 CI 绿色等同于正式发行。
`release-preview` 如需强制人工审批，应在 GitHub Environment 配置 required reviewers。

## 人工验收与回退

屏幕录制、Accessibility、真实前台输入框、IME、系统权限持久化及真实模型质量
不由无人值守 CI 证明。变更影响这些路径时，PR 必须记录具体人工验收结果。
现有 live foreground probe 仍是显式 opt-in，不计作已覆盖的真实桌面测试。

回退已合并变更使用新的 revert PR，经过相同 CI。失败版本不公开草稿；
已公开版本保留原 tag 和校验值，以新版本修复，不移动版本标签。

## 官方实践参考

2026-10-25 对照 DeepSeek 官方仓库读取了以下实现：

- [CI](https://github.com/deepseek-ai/deepseek-harness/blob/master/.github/workflows/ci.yml)：分层检查、取消过期运行、稳定汇总 required check。
- [真实 API E2E](https://github.com/deepseek-ai/deepseek-harness/blob/master/.github/workflows/e2e.yml)：真实密钥与无密钥门禁分开、配置缺失不能伪装成测试成功。
- [发布演练](https://github.com/deepseek-ai/deepseek-harness/blob/master/.github/workflows/release.yml) 和 [发布](https://github.com/deepseek-ai/deepseek-harness/blob/master/.github/workflows/release-publish.yml)：打包验证与写权限分离、发布使用已验证的同一份产物。
- [macOS 打包](https://github.com/deepseek-ai/deepseek-harness/blob/master/.github/workflows/macos-package.yml)：版本/来源验证、签名公证边界、安装包与诊断留存。

AgentOne 没有对应的 npm 公共包或 Web 部署，采用 macOS ZIP 草稿预发布。
暂不增加依赖付费模型和真实用户数据的必需检查。
