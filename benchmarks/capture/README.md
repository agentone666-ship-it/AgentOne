# Capture decision benchmark

## 当前：0.2.8 防误开启

自动模式初始不写文件。最近 3 秒中至少 60% 的 200 ms 窗口达到 -42 dBFS，观测跨度至少 2.4 秒且仍有新声音，才允许向启动确认推进；还需要 Laya 两次 ≥0.75 的 record 判断，间隔至少 1.5 秒（生产调度约 2 秒）。任何未知、低分、错误或持续声音消失都会取消待启动。

静音不会被“未知就录音”的兜底启动。已有录音保留尾段后返回听候，输入全部失联 5 秒也回听候；显式手动持续录音保留原行为。声音门限不是 VAD，持续噪声/音乐仍可能被视为声音；此版不声称能准确识别人声。

本机真实 Laya 对生产的四类标准化描述冒烟为 **4/4**，额外措辞探针 **7/8**；后者仍有错误。它们不测真实音频识别，也不等于误开启率。状态机/PCM 回归覆盖安静、输入未知、错误模型高分 record、单次点击、反复短声、持续声音、重复投票、录音尾段和 10 秒预录。报告见 start-028.json 与 start-028-wording.json；通过下方命令复现当前版本。

## 历史：0.2.6

下表与 baseline/candidate/holdout 文件保留原始结果。0.2.6 的“未知也录音”策略已被用户反馈否定，由 0.2.8 取代；不要再按旧保护层的分支分数推断当前行为。

固定模型 `convaiinnovations/laya/multilingual` revision `7b928d828b7b0e022f929d9bd2e44165aa270148`，SDK `laya==0.4.12`，本机 CPU。输入为合成声音状态描述，不包含用户音频，不衡量 VAD、ASR 或真实场景漏录率。

| 数据 | 模型原始选择 | 加入保护后的选择 |
|---|---:|---:|
| 原始复杂提示词 baseline | 1/12 | 未启用 |
| 中性 A/B 与精简输入 candidate | 10/12 | 12/12 |
| 未用来选择提示词的不同措辞 holdout | 4/8 | 7/8 |

candidate 实际是 6 种声音状态 × 2 种当前录音状态。精简后的模型只接收声音状态，所以两组不是独立样本。holdout 保留一个静音没有进入听候的失败案例；系统仍保存声音，属于保守多录。短暂停顿曾被模型错误建议听候，保护层拒绝。

保护层：只允许 `wait` 且所选答案概率 ≥0.75、静音 ≥15 秒、双输入已接入、录音至少 15 秒、连续两次 wait，才暂停写文件。低分、未知或错误继续保存。0.75 是工程门限，未做概率校准；SDK `answer_confidence` 是所选答案概率，旧字段 `confidence` 是归一化熵，不能互换。`action.act_probability` 不参与控制。

```bash
bash scripts/setup_laya.sh
python3 benchmarks/capture/run.py
python3 benchmarks/capture/run.py --holdout
swift test --filter 'RecordingDecisionTests|MixedAudioTests'
```

报告输出到 `build/benchmarks/`；此目录中的 baseline/candidate/holdout 是本次实测快照。保护后的分数只检查稳定决策应当采用的分支，不替代时间状态机测试，也不证明真实说话开头一定保全。原始模型表现仍不足以单独控制录音，后续应使用真实授权场景采样做专项评估/微调。
