# DeepSeek Harness (DSH) 与 AgentMonitor 的对接约定

> 本目录暂存 AgentMonitor 接入 DSH 所需的 **状态文件协议** 与 **DSH 端写入脚本**。
> 本地约定，等 AgentMonitor 的 FileWatcher PR（#3，跟随合千问 disabled 的 #2 之后）合入后再端到端打通。

## 目标

把 DSH（一个跑在浏览器 `http://127.0.0.1:3080` 下的 Web GUI）接入 AgentMonitor 的"被监控智能体"列表，
**不依赖 macOS Accessibility、不依赖屏幕截图**（按用户偏好排除截图方案）。仅靠 DSH 自己写一个
JSON 状态文件，AgentMonitor 定期读取。

## 文件路径

```
~/Library/Application Support/AgentMonitor/dsh-status.json
```

DSH 写入，AgentMonitor 读取。

## Status JSON 协议

最小可用版本（按 AgentMonitor 现有 `WatcherState` 枚举对齐）：

```jsonc
{
  "version": 1,
  "agent": "deepseek-harness",
  // 必填字段。值域严格枚举，AgentMonitor 端会兜底 unknown：
  //   "idle"        — 空闲，等待用户输入
  //   "working"     — 正在处理任务（生成、读文件、跑命令等）
  //   "needs_input" — 需要用户确认 / 补充信息 / 批准
  //   "completed"   — 当前任务已完成（短时间内可能 idle）
  //   "attention"   — 同 needs_input，兼容旧命名
  //   "error"       — 任务异常
  "status": "working",
  "task": {
    "id": "round-42",         // 可选；会话级 ID，AgentMonitor 用做去重
    "label": "修复 OCR bug",    // 可选；展示用标题
    "startedAt": 1755320000,   // 可选；unix 秒
    "updatedAt": 1755320123    // 可选；unix 秒；AgentMonitor 用做 TTL
  },
  "details": "思考中：调用 Edit..."  // 可选；AgentMonitor 详情面板/日志
}
```

AgentMonitor 读到 `updatedAt` 距今超过 `60s` 时把状态降级为 `idle`（持 working 的租约过期），
与 `OCRTemporalAggregator` 现有 lease 行为保持一致。

## DSH 端写入脚本

`dsh-status-writer.sh`（本目录）是一个零依赖的 bash 脚本，提供三种用法：

```bash
# 1) 直接写一个状态（CLI 任一时刻可调用）
dsh-status-writer.sh working "处理用户请求"

# 2) 一次会话内持续探测（轮询 DSH / 自己的回合判定逻辑，每 5s 写一次）
dsh-status-writer.sh watch

# 3) 配合 DSH 启动的 LaunchAgent，自动随 DSH 起停
#    见 dsh.com.cuishiming.dsh-status-writer.plist（本目录）
```

`dsh-status-writer.sh` 提供的写入：
- 路径固定：`~/Library/Application Support/AgentMonitor/dsh-status.json`
- 原子写：先写 `.tmp` 再 `mv`，避免半截写入
- 单实例 lock：`flock` 防止多源竞写

## 当前状态

- AgentMonitor 端：**FileWatcher 暂未实现**。等 AgentMonitor PR #3（将跟随 PR #2）合入后，
  本文件会被读取。请勿在没有 PR #3 合入前期待 DSH 状态在 AgentMonitor 浮岛显示。
- DSH 端：脚本本身可以现在就运行，但 DSH 本身没有自动 hook；要么手工触发，
  要么你自己用 `dsh-status-writer.sh` 串到 DSH 的 profile patch 上（需要 DSH 那一侧有
  plugin/hook 机制 —— 在 DSH 当前版本里未公开暴露，由 DSH 维护者后续支持）。

## 文件清单（本目录）

- `README.md` — 本文档
- `dsh-status-writer.sh` — bash 写入脚本（CLI / watch 模式）
- `dsh.com.cuishiming.dsh-status-writer.plist` — 选装 LaunchAgent（自动随 DSH 启停）

## 关联 PR / Issue

- AgentMonitor PR #2：`feat(qwenwork-disabled)` — 千问 disabled（已开）
- AgentMonitor PR #3：`feat(file-watcher-for-dsh)` — 后续 FileWatcher 实现
- （待开）DSH 上游：请求一个"agent-state.json"hook 或等价 plugin

## 隐私

DSH 状态文件是**本机本地**的，不会被自动上传。AgentMonitor 日志里的"details"字段默认
只写到 `/tmp/agentmonitor.launchd.log`，与已有 OCR 处理路径一致；不上传 NAS 与 GitHub。
