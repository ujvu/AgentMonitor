#!/bin/bash
# Build script for AgentMonitor — compiles Swift sources and creates a .app bundle.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
APP_NAME="AgentMonitor"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
SRC_DIR="${PROJECT_DIR}/Sources/AgentMonitor"
RES_DIR="${PROJECT_DIR}/Resources"

echo "🔨 Building ${APP_NAME}..."

# Clean and create build directory
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Find all Swift source files
SWIFT_FILES=$(find "${SRC_DIR}" -name '*.swift' | sort)

# Compile
echo "  Compiling Swift sources..."
swiftc \
    -O \
    -target arm64-apple-macos12.0 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -o "${BUILD_DIR}/${APP_NAME}" \
    ${SWIFT_FILES} \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework CoreGraphics \
    -framework ScreenCaptureKit \
    2>&1

if [ $? -ne 0 ]; then
    echo "❌ Compilation failed!"
    exit 1
fi

echo "  Creating .app bundle..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy executable
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Copy Info.plist
cp "${RES_DIR}/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

# Create PkgInfo
echo "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

# Set permissions
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Code-sign with a self-signed certificate so macOS TCC remembers the
# accessibility permission across rebuilds. Falls back to ad-hoc signing
# if the certificate isn't set up yet (run setup-cert.sh first).
echo "  Code signing..."
CERT_NAME="AgentMonitorDev"
if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    codesign --force \
        --sign "$CERT_NAME" \
        --identifier "com.cuishiming.AgentMonitor" \
        "${APP_BUNDLE}" 2>&1
    echo "  (signed with certificate: $CERT_NAME)"
else
    codesign --force --sign - \
        --identifier "com.cuishiming.AgentMonitor" \
        "${APP_BUNDLE}"
    echo "  (ad-hoc signed)"
fi

echo "✅ Build successful!"
echo "   App: ${APP_BUNDLE}"
echo ""
echo "To run: open \"${APP_BUNDLE}\""
echo ""
echo "Note: First launch requires Accessibility permission."
echo "  System Settings > Privacy & Security > Accessibility"
