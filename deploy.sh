#!/bin/bash
# Deploy script for AgentMonitor — build + ditto-replace into /Applications
# + relaunch.
#
# Why `ditto` (and never `rm -rf` + `cp`): replacing the bundle in place
# keeps the directory inode stable, which preserves the TCC (Accessibility /
# Screen Recording) grants and the Keychain ACL trust that macOS keys off
# the code-signing identity. A `rm -rf` would reset those, causing re-prompt
# on every launch.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AgentMonitor"
DEST="/Applications/${APP_NAME}.app"

echo "🔨 Building..."
"${PROJECT_DIR}/build.sh"

echo ""
echo "📦 Deploying to ${DEST} (ditto, in-place)..."
ditto "${PROJECT_DIR}/build/${APP_NAME}.app" "${DEST}"

echo "   inode: $(ls -di "${DEST}" | awk '{print $1}')"

# Restart the running app if any.
if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
    echo "   Quitting running instance..."
    pkill -x "${APP_NAME}" || true
    sleep 1
fi

echo "   Launching..."
open "${DEST}"
sleep 1
if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
    echo "✅ ${APP_NAME} deployed and running (PID $(pgrep -x ${APP_NAME}))"
else
    echo "⚠️  ${APP_NAME} launched but process not found — check log:"
    echo "   ~/Library/Logs/AgentMonitor/AgentMonitor.log"
fi
