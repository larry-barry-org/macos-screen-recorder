#!/bin/bash
# One-time setup: creates a stable, self-signed code-signing certificate in your
# login keychain so macOS remembers the app's Screen Recording permission across
# rebuilds (an ad-hoc signature changes every build and forces a re-prompt).
#
# Idempotent: if the identity already exists it does nothing, so it's safe to
# re-run — e.g. after erasing your Mac. It never creates duplicate keychain items.
set -euo pipefail

IDENTITY="ScreenRecorder Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "$IDENTITY"; then
    echo "✓ Signing identity '$IDENTITY' already installed — nothing to do."
    exit 0
fi

echo "▸ Creating self-signed code-signing certificate '$IDENTITY'…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = ScreenRecorder Dev
[ ext ]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout pass:sr -name "$IDENTITY" >/dev/null 2>&1

echo "▸ Importing into login keychain…"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P sr -A -T /usr/bin/codesign >/dev/null

echo "✓ Done. Now build with:  ./build.sh"
echo "  Grant Screen Recording permission once; it will persist across rebuilds."
