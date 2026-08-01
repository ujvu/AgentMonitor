#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/Tests/DetectionTest/build"
mkdir -p "${BUILD_DIR}"

SWIFT_FILES=()
while IFS= read -r file; do
    SWIFT_FILES+=("$file")
done < <(find "${PROJECT_DIR}/Sources/AgentMonitor" -name '*.swift' ! -name 'main.swift' | sort)

swiftc \
    -O \
    -target arm64-apple-macos12.0 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -o "${BUILD_DIR}/detectiontest" \
    "${SWIFT_FILES[@]}" \
    "${PROJECT_DIR}/Tests/DetectionTest/detectiontest.swift" \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework CoreGraphics \
    -framework ServiceManagement \
    -framework Vision \
    -framework CoreImage \
    -framework CoreVideo

"${BUILD_DIR}/detectiontest"
