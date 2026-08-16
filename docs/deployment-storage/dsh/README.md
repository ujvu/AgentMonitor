# DeepSeek Harness (DSH) 与 AgentMonitor 的对接约定

> 状态文件协议 + DSH 端写入脚本。**已端到端打通**：AgentMonitor 的
> `FileStatusWatcher`（主干 `agent/initial-release`，PR #3）每 2 秒轮询
> 本协议文件；写入端 `dsh-status-writer.sh` v2 起推导**真实状态**。

## 目标

把 DSH（一个跑在浏览器 `http://127.0.0.1:3080` 下的 Web GUI）接入 AgentMonitor 的"被监控智能体"列表，
**不依赖 macOS Accessibility、不依赖屏幕截图**（按用户偏好排除截图方案）。

## 文件路径

```
~/Library/Application Support/AgentMonitor/dsh-status.json
```

DSH 侧脚本写入，AgentMonitor `FileStatusWatcher` 读取。

## Status JSON 协议

```jsonc
{
  "version": 1,
  "agent": "deepseek-harness",
  // 值域（AgentMonitor 端会兜底 unknown → idle）：
  //   "idle"        — 空闲
  //   "working"     — 正在处理任务（生成、读文件、跑命令等）
  //   "needs_input" — 需要用户确认 / 补充信息 / 批准（映射浮岛"等待接手"）
  //   "completed"   — 当前任务已完成（短暂展示后回落 idle）
  //   "attention"   — 同 needs_input，兼容旧命名
  //   "error"       — 任务异常
  "status": "working",
  "task": {
    "startedAt": 1755320000,   // 可选；unix 秒
    "updatedAt": 1755320123    // 可选；unix 秒；AgentMonitor 用做 60s TTL
  },
  "details": "session transcript active (8s ago)"  // 可选；展示/日志
}
```

AgentMonitor 读到 `updatedAt` 距今超过 60s 时把状态降级为 idle（lease 过期），
与 `OCRTemporalAggregator` 行为一致。

## 写入端：dsh-status-writer.sh（v2，真实状态推导）

**不依赖 DSH 上游 hook**（DSH 是 npm 上的打包产物，无公开状态 API），从两个本地信号推导：

| 信号 | 采集方式 | 说明 |
|---|---|---|
| 服务器在线 | `lsof -nP -iTCP:3080 -sTCP:LISTEN` | DSH web 是否在跑 |
| 会话活跃 | `~/.dsh/sessions/**/session.jsonl.zstd` 最新 mtime | 实测：回合进行中转录约每 60s 批量落盘一次 |

状态机：

| 条件 | 写入状态 |
|---|---|
| 服务器不在线 | `idle`（details: server offline） |
| 最新转录 age ≤ 150s | `working`（覆盖 60s 落盘节拍 + 一轮容错） |
| 150s < age ≤ 330s | `completed`（回合刚结束） |
| age > 330s | `idle` |

用法：

```bash
dsh-status-writer.sh watch 5      # LaunchAgent 常驻模式（推荐）
dsh-status-writer.sh working "…"  # 手动覆盖（测试/纠偏）
```

工程细节：
- **原子写**：先写 `.tmp.$$` 再 `os.replace`，读方永远看不到半截 JSON
- **互斥锁**：macOS 无 `flock`，用 `mkdir` 原子性做锁；被抢方安静退出，无残留锁目录
- **日志节流**：watch 模式仅在状态**变化**时输出一行，避免 launchd 日志膨胀

### 已知局限

- **needs_input 无法从磁盘区分**：等待用户输入与回合结束都表现为"不再写入"。
  v2 不产生 `needs_input`；需要 DSH 上游提供官方状态 hook 后替换信号源。
- 落盘节拍（约 60s）是实测值，DSH 版本更新后需复核 `WORKING_MAX_AGE`。

## 安装（新机器）

```bash
mkdir -p ~/Library/AgentMonitor/scripts
cp dsh-status-writer.sh ~/Library/AgentMonitor/scripts/ && chmod +x ~/Library/AgentMonitor/scripts/dsh-status-writer.sh
# plist 中的脚本路径改为绝对路径后：
launchctl load -w ~/Library/LaunchAgents/com.cuishiming.dsh-status-writer.plist
```

> 注意：LaunchAgent 的 `ProgramArguments` 必须指向**本地稳定路径**
> （如 `~/Library/AgentMonitor/scripts/`），不要指向 OneDrive/iCloud 同步目录——
> launchd 对同步盘上的脚本会报 `Operation not permitted`。

## 端到端验证记录（2026-08-16）

```
10:04:51 dsh-status: <init> -> working (session transcript active (2s ago))
[02:04:53Z] MonitorEngine: [dsh] state idle → working   ← AgentMonitor 读到真实状态
[02:04:53Z] FloatingIsland hidden -> expanded            ← 浮岛联动
```

（02:04:53Z UTC = 本机 10:04:53；此状态由 DSH agent 自身活动触发——自指监控闭环。）
