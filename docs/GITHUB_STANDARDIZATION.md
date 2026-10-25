# GitHub 规范化落地记录（2026-10-25）

## STATUS

- 起始本地版本：`0612cf1`，工作区干净。
- GitHub `origin/main`：`e2461fe`，比本地少一笔 Memory 功能提交（30 个文件）。
- CI/CD 改动在 `codex/github-ci-cd`；本地全量验证通过。
- 用户已确认以当前本地项目为准；已有 Memory 提交和独立 CI/CD 提交均已推送主题分支。
- PR 云端 CI 和 main 分支保护正在验证，尚未合并。
- 尚未公开发布任何安装包。

## DECISIONS

1. 参考 DeepSeek 官方分层 CI、稳定汇总门禁、验证与发布隔离；不引入其大型 monorepo 或 self-hosted runner 配置。
2. 必需 CI 全部无真实模型密钥。真实 OAuth、系统授权与前台采集保留为人工验收。
3. 每个 PR 都验证最终 ZIP；仅在手动选择 main 上的版本 tag 后创建草稿预发布。
4. 同一份已验证 ZIP 进入 release，发布任务没有重新构建步骤。
5. 单维护者仓库采用 PR + CI 门禁，不要求作者批准自己的 PR。

## CHANGES

- 修复历史 CI：`npm test` 之前没有生产构建，干净 runner 缺少 `dist/index.js`。
  原失败证据：[run 33531007655](https://github.com/agentone666-ship-it/AgentOne/actions/runs/33531007655)。
- 新增共享 `scripts/ci.sh`，覆盖 Runtime、Memory MCP、Swift、集成和安装包。
- CI 增加 Node 支持下限/24 矩阵、actionlint、生产依赖审计、超时、并发取消、日志与 ZIP artifact。
- Actions 固定完整 commit SHA，checkout 不持久化凭证；仅草稿发布任务有写权限。
- Zod 锁文件从 4.4.3 更新到 4.6.7，修复审计发现的 high 漏洞，其余依赖不变。
- 新增 Dependabot、CODEOWNERS、PR 模板、功能建议模板、版本文件和操作指南。
- App Info.plist 产品版本读取 package.json，不再独立硬编码。

## TESTS

本地 macOS / Swift 6.1.2 / Node 22.22.1 / Deno 2.8.0：

- `npm ci` 后移开旧 `dist`、`dist-test`，执行 `bash scripts/ci.sh all`：通过。
- TypeScript：56 tests passed。
- Swift：94 tests passed（live foreground probe 无真实会话参数，不算真实桌面覆盖）。
- Memory MCP：初始化、工具列表、跨月查询、敏感事件排除：通过。
- Core Harness：29 checks；Pi Bridge：15 checks；OAuth fixture：5 checks；Credential Store：7 checks；Model Runtime Harness：通过。
- 最终 Release ZIP：签名、内嵌 Sidecar、localhost API/Kimi 协议、隐私零外发、错误恢复、并发 ID、关闭重启：通过。
- `npm audit --omit=dev --audit-level=high`：0 vulnerabilities。
- actionlint 1.7.12、Bash/Zsh 语法、`git diff --check`：通过。

本地通过不代表 GitHub runner 通过；远端结果须另外记录。
发布流程已静态检查，尚未创建版本标签或执行草稿 release。

## HANDOFF

- 入口与日常操作：[CI_CD.md](CI_CD.md)。
- 同步范围已确认；通过 PR 验证实际 GitHub CI，并补记运行结果。
- 远端全绿后配置 main required check 和仓库合并设置，回读确认实际生效。
- Developer ID、公证、正式升级通道、真实模型质量和系统权限验收仍不在已完成范围内。
