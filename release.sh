#!/bin/bash
# Build, sign, package, notarize, and verify an official macOS release.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AgentMonitor"
APP_BUNDLE="${PROJECT_DIR}/build/${APP_NAME}.app"
DIST_DIR="${PROJECT_DIR}/dist"
INFO_PLIST="${PROJECT_DIR}/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_PROFILE:-AgentMonitorNotary}"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}-macOS-arm64.dmg"

if [ -z "$SIGNING_IDENTITY" ]; then
    echo "❌ DEVELOPER_ID_APPLICATION is required."
    echo "Example: DEVELOPER_ID_APPLICATION='Developer ID Application: Name (TEAMID)' ./release.sh"
    exit 2
fi

if ! security find-identity -p codesigning 2>/dev/null | grep -Fq "$SIGNING_IDENTITY"; then
    echo "❌ Developer ID identity is not installed or unlocked: $SIGNING_IDENTITY"
    exit 2
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    echo "❌ Notary profile is unavailable: $NOTARY_KEYCHAIN_PROFILE"
    echo "Create it with: xcrun notarytool store-credentials $NOTARY_KEYCHAIN_PROFILE"
    exit 2
fi

echo "🔨 Building signed application..."
CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" REQUIRE_SIGNING=1 "${PROJECT_DIR}/build.sh"

echo "🔍 Verifying application signature..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

mkdir -p "$DIST_DIR"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentmonitor-release.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_BUNDLE" "${STAGING_DIR}/${APP_NAME}.app"

echo "📦 Creating DMG..."
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

codesign --force \
    --sign "$SIGNING_IDENTITY" \
    --timestamp \
    "$DMG_PATH"

echo "☁️  Submitting for Apple notarization..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait

echo "📎 Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

echo "✅ Release ready: $DMG_PATH"
shasum -a 256 "$DMG_PATH"
