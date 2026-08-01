# AgentMonitor

macOS **AI Dynamic Island 多 Agent 控制中心** —— 一个菜单栏常驻应用,用像素风悬浮岛实时呈现所有 AI Agent 桌面应用(ZCode / 千问办公 / WorkBuddy / ChatGPT)的工作状态。

```
                    ┌─────────────────────────────────────┐
  屏幕顶部           │  🤖 Z CODE          WORKING  ▓▓▓▓▓▓░ │
                    └─────────────────────────────────────┘
```

## 功能特性

- **多 Agent 状态检测**:AX 辅助功能 + Vision OCR 双通道,Electron 类应用(canvas 渲染)也能识别 working / completed / needsAttention
- **Fusion 状态融合**:多证据源按优先级融合,upgrade 快速确认(1 次)、downgrade 谨慎确认(3 次),避免状态抖动
- **Dynamic Island 产品层**:
  - `IslandScene` 场景驱动渲染(渲染层零业务判断)
  - `IslandPresentationEngine` 状态 → 场景映射
  - `IslandRotationManager` 多 working agent 每 2s 轮换(交叉淡出/淡入)
  - `IslandAnimationEngine` CVDisplayLink vsync 驱动 + 序列形变 + sequenceId 取消机制
  - `PixelAgentVisual` 每 agent 专属像素角色(猫/狼/凤凰/独角兽,idle/working/completed 动画)
- **交互**:hover 缓慢渐进展开(450ms)→ 单击收起 → 双击跳到对应 agent 窗口
- **额度中心**:MiniMax / GLM / DeepSeek 真实 API 额度查询，明确显示每个窗口的**剩余额度百分比**和官方返回的**重置/恢复时间**；Keychain 存储(ACL 免密码)
- **Attention 识别**:确认弹窗的强/弱关键词 + 编号列表评分

## 架构

```
AXDetector / VisionDetector (OCR)      —— 状态感知
        ↓
FusionEngine                           —— 证据融合
        ↓
AppWatcher                             —— 提交 StateSnapshot + StateEvent
        ↓
IslandPresentationEngine               —— 状态 → IslandScene(产品层)
        ↓
IslandRotationManager                  —— 多 agent 场景选择与轮换
        ↓
FloatingIsland                         —— 纯渲染(零 AgentStatus 判断)
        ↓
IslandAnimationEngine                  —— CVDisplayLink 逐帧形变驱动
```

## 构建与部署

```bash
# 1. 构建(编译 + 打包 + codesign + 验证)
./build.sh

# 2. 部署到 /Applications(ditto 内容覆盖,保留 inode/TCC/Keychain 权限)
ditto build/AgentMonitor.app /Applications/AgentMonitor.app

# 3. 运行
open /Applications/AgentMonitor.app
```

### 三套真实场景回归

测试使用真实桌面采样中出现的文案，覆盖 WorkBuddy、Z Code、ChatGPT Worker 的 working / attention / completed 三态：

```bash
# 不依赖正在运行的应用，运行 OCR 规则回归
./Tests/DetectionTest/build_and_run.sh

# 只读采样当前桌面；目标应用未打开时会 SKIP，不会点击或输入
./Tests/LiveSceneTest/build_and_run.sh
```

> ⚠️ **部署约束**:必须用 `ditto` 内容覆盖,禁止 `rm -rf + cp`(会重置 TCC/Keychain 权限,导致每次启动重新授权)。

首次启动需要授权:
- **辅助功能**(AX 检测):系统设置 → 隐私与安全 → 辅助功能
- **屏幕录制**(OCR 截图):系统设置 → 隐私与安全 → 屏幕录制

## 配置

- **API Key**:菜单栏 → AI 额度中心 → 配置(GLM / MiniMax / DeepSeek)。Key 只存 Keychain,绑定应用 ACL,不写日志/明文文件
- **通知方式**:不使用 macOS 系统通知；状态、确认和额度恢复提醒统一显示在悬浮岛中
- **完成提醒**:任务完成时悬浮岛显示 3 秒庆祝卡并播放 `Glass` 音效；可用 `defaults write com.cuishiming.AgentMonitor DisableCompletionSound -bool true` 关闭
- **调试**:
  - `defaults write com.cuishiming.AgentMonitor OCRDebug -bool true` — OCR 调试(截图 + 识别文本)
  - `defaults write com.cuishiming.AgentMonitor TestQuotaRecovery -bool true` — 模拟额度恢复弹窗

## 目录结构

```
Sources/AgentMonitor/
├── AppDefinitions.swift        — 各 agent 的 AX/OCR 规则
├── AppWatcher.swift            — 每 app 一个 watcher(轮询 + OCR + 状态机)
├── AXUtilities.swift           — AX 辅助功能封装
├── VisionDetector.swift        — Vision OCR + 关键词匹配 + 位置过滤
├── FusionEngine.swift          — 证据融合
├── SignalDetector.swift        — 按钮/信号检测(继续/批准/停止/发送)
├── AttentionDetector.swift     — 确认弹窗评分
├── FloatingIsland.swift        — 悬浮岛窗口 + 渲染(场景驱动)
├── IslandScene.swift           — IslandMode / IslandAnimation / IslandScene
├── IslandPresentationEngine.swift — 状态 → 场景
├── IslandRotationManager.swift — 多 agent 轮换
├── IslandAnimationEngine.swift — CVDisplayLink 形变引擎
├── IslandSceneTransition.swift — 场景交叉淡出/淡入
├── PixelTheme.swift            — 像素绘制基元 + 主题
├── PixelAgentVisual.swift      — 每 agent 像素角色(idle/working/completed)
└── Quota/                      — 额度中心(provider + keychain)
```

## 日志

`~/Library/Logs/AgentMonitor/AgentMonitor.log` — 状态切换、动画序列、额度刷新、hover 交互全记录。

## GitHub 检查

推送或提交 Pull Request 后，GitHub Actions 会在 macOS runner 上自动执行应用构建、OCR 规则回归和悬浮岛动画引擎测试。实时桌面采样测试需要本机打开目标应用，因此不纳入无桌面的 CI 流程。

## 正式发布

正式 DMG 必须使用 Apple Developer ID 签名并通过 Apple 公证。发布脚本不会在缺少证书或公证凭据时降级生成未公证安装包。

```bash
# 一次性保存公证凭据（命令会交互式询问 Apple ID、Team ID 和 app-specific password）
xcrun notarytool store-credentials AgentMonitorNotary

# 构建、Developer ID 签名、制作 DMG、提交公证、staple 并验证
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" ./release.sh
```

产物输出到 `dist/AgentMonitor-<version>-macOS-arm64.dmg`。证书和公证凭据只保存在本机 Keychain，不写入仓库。

## 验收清单(产品闭环)

- [x] 多 Agent 状态检测(AX + OCR + Fusion)
- [x] 状态 → 场景 → 渲染三层分离(FloatingIsland 零 AgentStatus)
- [x] 多 agent 轮换 + 交叉淡出/淡入(几何保持,只换内容)
- [x] CVDisplayLink vsync 展开/收起序列(450ms hover / 750ms show)
- [x] Pixel 角色动画(idle / working / completed)
- [x] hover 单击收起 / 双击跳页
- [x] 额度中心 + Keychain ACL
- [x] ChatGPT Worker 采样、working/attention/completed 规则与回归测试
- [x] WorkBuddy / Z Code / ChatGPT 三套真实 OCR 场景夹具
- [ ] ChatGPT Worker 的真实 attention/completed 现场验收（需要对应任务自然进入这两个状态）
