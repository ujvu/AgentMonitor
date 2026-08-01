#!/bin/bash
# Build script for AgentMonitor — compiles Swift sources and creates a .app bundle.
# Does NOT wipe the build directory: we overwrite files in place so the
# code-signing identity stays stable across rebuilds (macOS TCC keys the
# accessibility grant off the designated requirement, which is tied to the
# certificate/identifier, so a stable signed bundle avoids re-prompting).
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
APP_NAME="AgentMonitor"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
SRC_DIR="${PROJECT_DIR}/Sources/AgentMonitor"
RES_DIR="${PROJECT_DIR}/Resources"
ENTITLEMENTS="${RES_DIR}/AgentMonitor.entitlements"
IDENTIFIER="com.cuishiming.AgentMonitor"
CERT_NAME="AgentMonitorDev"

echo "🔨 Building ${APP_NAME}..."

# Ensure build directory exists (do NOT remove it — keeps binary identity stable).
mkdir -p "${BUILD_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Find all Swift source files.
SWIFT_FILES=$(find "${SRC_DIR}" -name '*.swift' | sort)

# Compile (no ScreenCaptureKit — we use CGWindowList APIs).
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
    -framework ServiceManagement \
    -framework Vision \
    -framework CoreImage \
    -framework CoreVideo \
    2>&1

if [ $? -ne 0 ]; then
    echo "❌ Compilation failed!"
    exit 1
fi

# Copy executable into the bundle (overwrite in place).
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Ensure executable permission is set (required for macOS to launch the app).
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Copy Info.plist (overwrite in place).
cp "${RES_DIR}/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

# Create PkgInfo if missing.
if [ ! -f "${APP_BUNDLE}/Contents/PkgInfo" ]; then
    echo "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"
fi

# Set executable permissions.
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Code-sign with entitlements.
# Uses the AgentMonitorDev self-signed certificate when present so macOS TCC
# remembers the Accessibility grant across rebuilds. Falls back to ad-hoc
# signing if the certificate isn't set up (run setup-cert.sh first).
echo "  Code signing..."
if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    codesign --force \
        --sign "$CERT_NAME" \
        --identifier "${IDENTIFIER}" \
        --entitlements "${ENTITLEMENTS}" \
        --options runtime \
        "${APP_BUNDLE}" 2>&1
    echo "  (signed with certificate: $CERT_NAME, entitlements applied)"
else
    codesign --force \
        --sign - \
        --identifier "${IDENTIFIER}" \
        --entitlements "${ENTITLEMENTS}" \
        "${APP_BUNDLE}" 2>&1
    echo "  (ad-hoc signed, entitlements applied)"
fi

# Verify the signature.
echo "  Verifying code signature..."
if codesign --verify --verbose=2 "${APP_BUNDLE}" 2>&1; then
    echo "  ✅ Signature verified."
else
    echo "  ⚠️ Signature verification reported issues (may still run)."
fi

echo "✅ Build successful!"
echo "   App: ${APP_BUNDLE}"
echo ""
echo "To run: open \"${APP_BUNDLE}\""
echo ""
echo "Note: First launch requires Accessibility permission."
echo "  System Settings > Privacy & Security > Accessibility"
