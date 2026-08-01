#!/bin/bash
# One-off DEBUG build of AgentMonitor (UI-test remote control enabled).
# Mirrors build.sh exactly, plus -D DEBUG. Used only for automated UI tests;
# the normal ./build.sh (release) is re-run afterwards.
set -euo pipefail
PROJECT_DIR="/Users/cuishiming/.qwenworkcn/workspace/ms7kj1xndatgqswv/outputs/AgentMonitor"
BUILD_DIR="${PROJECT_DIR}/build"
APP_NAME="AgentMonitor"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
SRC_DIR="${PROJECT_DIR}/Sources/AgentMonitor"
RES_DIR="${PROJECT_DIR}/Resources"
ENTITLEMENTS="${RES_DIR}/AgentMonitor.entitlements"
IDENTIFIER="com.cuishiming.AgentMonitor"
CERT_NAME="AgentMonitorDev"

mkdir -p "${BUILD_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

SWIFT_FILES=$(find "${SRC_DIR}" -name '*.swift' | sort)
echo "  Compiling Swift sources (-D DEBUG)..."
swiftc \
    -O \
    -D DEBUG \
    -target arm64-apple-macos12.0 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -o "${BUILD_DIR}/${APP_NAME}" \
    ${SWIFT_FILES} \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework CoreGraphics \
    -framework ServiceManagement \
    -framework Vision \
    -framework CoreImage \
    -framework CoreVideo \
    2>&1

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "${RES_DIR}/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
if [ ! -f "${APP_BUNDLE}/Contents/PkgInfo" ]; then
    echo "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"
fi

if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    codesign --force --sign "$CERT_NAME" --identifier "${IDENTIFIER}" \
        --entitlements "${ENTITLEMENTS}" --options runtime "${APP_BUNDLE}" 2>&1
else
    codesign --force --sign - --identifier "${IDENTIFIER}" \
        --entitlements "${ENTITLEMENTS}" "${APP_BUNDLE}" 2>&1
fi
codesign --verify --verbose=1 "${APP_BUNDLE}" 2>&1
echo "✅ DEBUG build done: ${APP_BUNDLE}"
