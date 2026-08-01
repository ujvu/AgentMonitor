# AgentMonitor 路线图

最后更新：2026-08-01

---

## 🔜 近期任务

### ChatGPT Worker 模式监控（规则与采样已完成）

**背景**
ChatGPT 桌面端有两种模式，界面完全不同：
- **Chat 模式**：响应快，无需监控（用户判断）
- **Worker 模式**：长任务执行，需要监控 working / attention / completed

**当前状态**
- 已在真实 Worker 长任务中采集到 `已处理`、`正在运行命令`、`运行了命令`、`第 1/5 步`、`Verifying`、`Investigating` 等状态证据
- 已将 ChatGPT OCR 区域切换为主会话窗口，并加入 Worker 的 working / attention / completed 规则
- 已修复 ChatGPT 宠物/辅助窗口被误选的问题：优先选择最大主窗口；主窗口直接截图为空时，活动窗口回退到当前显示器裁剪
- 仍需等任务自然进入 attention 和 completed 状态，做一次现场验收；规则回归已由真实采样文本覆盖

**待办**
1. 等待一个 Worker 任务自然出现确认请求，现场核对 attention 文案
2. 等待一个 Worker 任务自然完成，现场核对 completed 文案
3. 用 `Tests/DetectionTest/build_and_run.sh` 运行三套真实采样回归
4. 用 `Tests/LiveSceneTest/build_and_run.sh` 读取当前桌面窗口做只读冒烟测试

**注意**
- ChatGPT bundleId 是 `com.openai.codex`（不是 com.openai.chatgpt）
- 可执行文件名是 `ChatGPT`
- Worker 模式可能复用同一窗口，只是内容不同

---

## 📋 其他已知待办

- **Pixel 材质层**：`PixelTheme.drawGlassBackground` / `drawInnerGlow` 已实现但未接入 draw()（用户反馈当前简洁风格更佳，函数保留备用）
- **AttentionDetector 持续调优**：真实弹窗样本积累后微调评分权重；各 app 强/弱关键词按实际弹窗文字细化
- **多 Agent 场景实测**：真实多 working agent 的 2s 轮换交叉淡出（已用 TestMultiRotate 验证过机制，待真实场景确认）
- **性能监控**：检测层 CPU 守卫已加（无窗口跳过 AX），可进一步观察长期运行的内存/日志增长

---

## ✅ 已完成

### 检测层
- 多 Agent 状态检测（AX + OCR 融合）
- 状态认知层（Evidence / FusionEngine / StateSnapshot / StateEvent）
- OCR 回退检测（Electron 类 Agent：ZCode / WorkBuddy / ChatGPT）
- 状态死锁修复（working→idle 回退，upgrade=1 / downgrade=3 确认）
- zcode working 关键词鲁棒化（「继续输入以排队」→「输入以排队/排队后续」+ confidence 阈值 0.45，解决 OCR 误识别「继」→「陛」导致状态丢失）
- zcode completed 关键词（「提出后续修改要求」——完成态输入框 placeholder）
- 检测层 CPU 守卫（app 无可见窗口时跳过 AX 遍历，保持上态；CPU 30%+ → <1%）

### Dynamic Island 产品层
- IslandScene / PresentationEngine / RotationManager / AnimationEngine 四层闭环
- CVDisplayLink vsync 驱动形变引擎（回调线程纯计算，main.async 应用；sequenceId 取消机制；空闲自动 Stop）
- show() 三段展开序列（awakening 弹高 → awakening 展开 → contentFadeIn）
- hide() 三段收起序列（contentFadeOut → collapsing → dormant）
- 多 agent 轮换交叉淡出/淡入（IslandSceneTransition，几何保持只换内容；已用 TestMultiRotate 3 mock 验证 A→B→C→A）
- hover 缓慢渐进展开（installHoverHitRegion 同步引擎几何 + expandFromHover 450ms，修复"闪两下"）
- 单击收起 / 双击跳页（250ms 单击延迟 + clickCount 判定）
- dismiss 生命周期修复（hide() 幂等保护 + IslandDisplayMode.collapsing + show() 重置 pendingHide）
- 能量条布局（bottomInset 6 / barHeight 6，与标题间距）
- 渲染撕裂修复（applyMorph 用 setFrame(display:true) 同步提交）

### Pixel 角色（PixelAgentVisual）
- 每 agent 专属像素角色：zcode 猫 / workbuddy 狼 / qwenwork 凤凰 / chatgpt 独角兽
- idle / working / completed 三态动画（像素友好：位移/闪烁/帧切换/亮度，无旋转；独立 phase 时钟不绑 animFrame）
- unknown appId fallback 到 PixelTheme.drawRobotHead

### 额度中心
- MiniMax（5小时+周）/ GLM（5小时+月+周）/ DeepSeek（余额）真实 API
- 每个订阅额度窗口显示剩余百分比和官方 `resetAt` 重置时间；DeepSeek 按量账户显示账户余额
- 额度恢复弹窗提醒（点击关闭）
- 不使用 macOS `UNUserNotificationCenter`，所有提醒走悬浮岛
- Keychain ACL 绑定（应用自保存 key 绑定受信任应用，重启免密码）
- Keychain 迁移机制（RestoreKey 一次性迁移，先删后建绑定新 ACL，迁移在 quotaManager.start() 前执行）

### 工程化
- PixelTheme 死代码清理（statusColor/statusLabel/statusIcon 已删，PixelTheme 不再依赖 AgentStatus）
- build.sh 移除无用的 -D DEBUG
- README.md / ROADMAP.md 文档化
