#!/usr/bin/env bash
# dsh-status-writer.sh — DeepSeek Harness 状态写入工具（v2：真实状态推导）
#
# 用法：
#   dsh-status-writer.sh <status> [details]        # 手动覆盖写入（测试/纠偏）
#   dsh-status-writer.sh watch [interval_seconds]  # 持续推导真实状态并写入
#
# 目标文件（AgentMonitor FileStatusWatcher 每 2s 轮询）：
#   ~/Library/Application Support/AgentMonitor/dsh-status.json
#
# ── v2 推导逻辑（不依赖 DSH 上游 hook、不依赖截图）────────────────────
# 信号 1：DSH web 服务器是否监听 127.0.0.1:3080（lsof）
# 信号 2：~/.dsh/sessions/**/session.jsonl.zstd 的最新 mtime
#         （实测：agent 回合进行中转录约每 60s 批量落盘一次）
#
# 状态机：
#   服务器不在线                  → idle     (details: server offline)
#   最新转录 age ≤ 150s           → working  （覆盖 60s 落盘节拍 + 一轮容错）
#   150s < age ≤ 330s             → completed（刚结束回合的"收尾"窗口）
#   age > 330s                    → idle
#
# 已知局限（无上游 hook 无法区分）：等待用户输入（needs_input）与回合
# 结束在磁盘上表现相同（都是不再写入），故本脚本不产生 needs_input。
# AgentMonitor 侧映射保持不变；未来 DSH 提供官方状态 hook 后可替换信号源。
#
# 与 AgentMonitor 对齐的 status 取值：
#   idle | working | needs_input | completed | attention | error

set -euo pipefail

STATUS_DIR="${HOME}/Library/Application Support/AgentMonitor"
STATUS_FILE="${STATUS_DIR}/dsh-status.json"
LOCK_DIR="${STATUS_DIR}/.dsh-status.lockdir"
PROTOCOL_VERSION=1

# 推导参数（秒）
DSH_PORT=3080
WORKING_MAX_AGE=150
COMPLETED_MAX_AGE=330
SESSIONS_ROOT="${HOME}/.dsh/sessions"

mkdir -p "${STATUS_DIR}"

write_status() {
  local status="$1"
  local details="${2:-}"

  # macOS 无 flock；用 mkdir 原子性做互斥文件锁。
  if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    echo "another writer holds the lock; aborting" >&2
    return 0
  fi
  trap 'rmdir "${LOCK_DIR}" 2>/dev/null || true' EXIT

  python3 - "$1" "$2" "$PROTOCOL_VERSION" "$STATUS_FILE" <<'PY'
import json, os, sys, time
status, details, proto, out_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
now = int(time.time())
payload = {
    "version": proto,
    "agent": "deepseek-harness",
    "status": status,
    "task": {
        "startedAt": now,
        "updatedAt": now,
    },
    "details": details,
}
text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
tmp_path = out_path + ".tmp." + str(os.getpid())
with open(tmp_path, "w", encoding="utf-8") as f:
    f.write(text)
os.chmod(tmp_path, 0o600)
os.replace(tmp_path, out_path)
PY

  rmdir "${LOCK_DIR}" 2>/dev/null || true
  trap - EXIT
}

# ── 信号采集 ────────────────────────────────────────────────

dsh_server_online() {
  lsof -nP -iTCP:"${DSH_PORT}" -sTCP:LISTEN 2>/dev/null | grep -q .
}

# 输出最新 session 转录的 age（秒）；无文件输出空串。
newest_transcript_age() {
  local newest=0 f m now
  now=$(date +%s)
  while IFS= read -r -d '' f; do
    m=$(stat -f %m "$f" 2>/dev/null) || continue
    (( m > newest )) && newest=$m
  done < <(find "${SESSIONS_ROOT}" -name 'session.jsonl.zstd' -type f -print0 2>/dev/null)
  [[ ${newest} -gt 0 ]] && echo $(( now - newest )) || echo ""
}

derive_status() {
  if ! dsh_server_online; then
    echo "idle|dsh server offline (port ${DSH_PORT} not listening)"
    return
  fi
  local age
  age=$(newest_transcript_age)
  if [[ -z "${age}" ]]; then
    echo "idle|server online, no session transcripts yet"
  elif (( age <= WORKING_MAX_AGE )); then
    echo "working|session transcript active (${age}s ago)"
  elif (( age <= COMPLETED_MAX_AGE )); then
    echo "completed|round finished (${age}s since last transcript write)"
  else
    echo "idle|no recent activity (${age}s idle)"
  fi
}

# ── 模式分发 ────────────────────────────────────────────────

if [[ "${1:-}" == "watch" ]]; then
  interval="${2:-5}"
  echo "dsh-status-writer.sh: watch mode v2 (derive from lsof + transcript mtime), interval=${interval}s" >&2
  last=""
  while true; do
    derived=$(derive_status)
    status="${derived%%|*}"
    details="${derived#*|}"
    # 只有状态变化时打印 stdout 日志，避免 LaunchAgent 日志膨胀
    if [[ "${status}" != "${last}" ]]; then
      echo "$(date '+%H:%M:%S') dsh-status: ${last:-<init>} -> ${status} (${details})"
      last="${status}"
    fi
    write_status "${status}" "${details}"
    sleep "${interval}"
  done
  exit 0
fi

if [[ $# -lt 1 ]]; then
  cat <<USAGE >&2
Usage:
  $0 <status> [details]          # one-shot manual write (override)
  $0 watch [interval_seconds]    # derive real status: lsof(3080) + transcript mtime
Allowed status: idle | working | needs_input | completed | attention | error
USAGE
  exit 2
fi

write_status "$1" "${2:-}"
echo "wrote ${STATUS_FILE}: status=$1"
