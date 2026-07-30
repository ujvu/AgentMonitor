#!/bin/bash
# One-time setup: creates a self-signed code signing certificate so that
# macOS TCC remembers the accessibility permission across rebuilds.
set -euo pipefail

CERT_NAME="AgentMonitorDev"

# Check if certificate already exists
if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ 代码签名证书 '$CERT_NAME' 已存在，跳过创建。"
    exit 0
fi

echo "🔨 创建自签名代码签名证书 '$CERT_NAME'..."

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Generate key and self-signed certificate (valid 10 years)
openssl req -x509 \
    -newkey rsa:2048 \
    -keyout "$TMP_DIR/AM.key" \
    -out "$TMP_DIR/AM.crt" \
    -days 3650 \
    -nodes \
    -subj "/CN=$CERT_NAME" \
    2>/dev/null

# Package as P12
openssl pkcs12 -export \
    -in "$TMP_DIR/AM.crt" \
    -inkey "$TMP_DIR/AM.key" \
    -out "$TMP_DIR/AM.p12" \
    -passout pass:amtemp123 \
    2>/dev/null

# Import to login keychain, allowing codesign to use it
security import "$TMP_DIR/AM.p12" \
    -k ~/Library/Keychains/login.keychain-db \
    -P amtemp123 \
    -T /usr/bin/codesign \
    -T /usr/bin/security

# Also import the certificate (not just the key) for trust
security import "$TMP_DIR/AM.crt" \
    -k ~/Library/Keychains/login.keychain-db \
    -T /usr/bin/codesign

# Trust the certificate for code signing
# This adds it to the "always trust" list for codesigning
security add-trusted-cert -d \
    -r trustAsRoot \
    -k ~/Library/Keychains/login.keychain-db \
    "$TMP_DIR/AM.crt" 2>/dev/null || true

echo ""
echo "✅ 证书创建成功！"
echo ""
echo "⚠️  macOS 可能弹出对话框要求授权，请点击「始终允许」。"
echo ""
echo "现在可以运行 build.sh 重新编译，之后重启不会再要求辅助功能权限。"
