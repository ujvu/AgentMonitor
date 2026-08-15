#!/usr/bin/env bash
# dsh-status-writer.sh — DeepSeek Harness 状态写入工具
#
# 用法：
#   dsh-status-writer.sh <status> [details]        # 单次写入
#   dsh-status-writer.sh watch [interval_seconds]  # 持续探测（DSH 端 hook 未开前为占位 noop）
#
# 目标文件：
#   ~/Library/Application Support/AgentMonitor/dsh-status.json
#
# 与 AgentMonitor 对齐的 status 取值：
#   idle | working | needs_input | completed | attention | error

set -euo pipefail

STATUS_DIR="${HOME}/Library/Application Support/AgentMonitor"
STATUS_FILE="${STATUS_DIR}/dsh-status.json"
LOCK_DIR="${STATUS_DIR}/.dsh-status.lockdir"
PROTOCOL_VERSION=1

mkdir -p "${STATUS_DIR}"

write_status() {
  local status="$1"
  local details="${2:-}"

  # macOS 无 flock；用 mkdir 原子性做互斥文件锁。
  # mkdir 在文件已存在时返回 EEXIST，可以无竞用地占锁。
  if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    echo "another writer holds the lock; aborting" >&2
    return 0
  fi

  # 释放锁（不论成功失败）
  trap 'rmdir "${LOCK_DIR}" 2>/dev/null || true' EXIT

  # 让 Python 来生成 JSON，避免 bash heredoc + 转义 + 单引号内 JSON 编码等痛苦
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

if [[ "${1:-}" == "watch" ]]; then
  interval="${2:-5}"
  echo "dsh-status-writer.sh: watch mode, interval=${interval}s (no DSH hook yet — will be noop until AgentMonitor FileWatcher is wired)" >&2
  while true; do
    # DSH 端目前没有官方 hook 让脚本感知回合变化。
    # 这里保守地写一帧 "idle" 维持协议通道，DSH 端 hook 接入后会被真实状态覆盖。
    write_status "idle" "watch loop tick (no DSH hook bound yet)"
    sleep "${interval}"
  done
  exit 0
fi

if [[ $# -lt 1 ]]; then
  cat <<USAGE >&2
Usage:
  $0 <status> [details]          # one-shot write
  $0 watch [interval_seconds]    # background poll (placeholder until DSH hook exists)
Allowed status: idle | working | needs_input | completed | attention | error
USAGE
  exit 2
fi

write_status "$1" "${2:-}"
echo "wrote ${STATUS_FILE}: status=$1"
