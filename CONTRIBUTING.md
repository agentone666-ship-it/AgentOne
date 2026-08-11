# Contributing to AgentOne

AgentOne 仍处于快速迭代期。提交变更时，请把“用户能否理解和控制自己的 Context”放在功能数量之前。

## 开发流程

1. 用 Issue 或变更说明写清用户问题、Context 输入、预期状态变化和隐私边界。
2. 把可测试规则放入 `AgentOneCore`，避免只在 SwiftUI 中实现行为。
3. 为 Context 链路增加单元测试、Harness 或真实 JSONL 进程 E2E。
4. 运行 `./scripts/test_e2e.sh`。
5. 检查截图、日志、fixture 和 diff 中没有真实用户数据或凭证。

## 提交规范

建议使用简洁的 Conventional Commit 风格：

```text
feat(context): aggregate repeated reading signals
fix(ocr): reconcile committed IME text on return
docs(privacy): clarify screenshot retention boundary
test(sidecar): cover overlapping JSONL request ids
```

一个提交尽量只包含一个可解释的变化。不要提交 `.build`、`build`、`node_modules`、Agent Home、日记、模型调用日志或真实截图。

## Pull Request 清单

- [ ] 用户问题和产品行为清晰。
- [ ] 隐私策略先于模型和持久化执行。
- [ ] 没有按键注入、事件重放或阻塞用户输入。
- [ ] 高频 Hook 已聚合，不会制造重复日记。
- [ ] 已增加对应层级的测试。
- [ ] 完整 E2E 通过。
- [ ] 文档和截图已更新且完全脱敏。
