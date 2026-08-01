#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/Tests/EngineTest/build"
mkdir -p "${BUILD_DIR}"

swiftc \
    -O \
    -target arm64-apple-macos12.0 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -o "${BUILD_DIR}/enginetest" \
    "${PROJECT_DIR}/Sources/AgentMonitor/IslandAnimationEngine.swift" \
    "${PROJECT_DIR}/Sources/AgentMonitor/PermissionManager.swift" \
    "${PROJECT_DIR}/Sources/AgentMonitor/Logger.swift" \
    "${PROJECT_DIR}/Tests/EngineTest/enginetest.swift" \
    -framework Cocoa

"${BUILD_DIR}/enginetest"
