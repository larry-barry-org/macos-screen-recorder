#!/bin/bash
# One-time setup: creates a stable, self-signed code-signing certificate in your
# login keychain AND trusts it for code signing, so macOS can validate the app's
# signature and remember its Screen Recording permission across rebuilds.
#
# (An ad-hoc signature changes every build and forces a re-prompt; an *untrusted*
# self-signed cert makes macOS show the permission as enabled but keep asking.)
#
# Idempotent: if the identity already exists and is trusted it does nothing, so
# it's safe to re-run — e.g. after erasing your Mac. It never creates duplicate
# keychain items.
set -euo pipefail

IDENTITY="ScreenRecorder Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Already fully set up? (find-identity -v only lists *valid*, i.e. trusted ids.)
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "✓ Signing identity '$IDENTITY' already installed and trusted — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Create + import the certificate if it doesn't exist yet.
if ! security find-identity -p codesigning | grep -q "$IDENTITY"; then
    echo "▸ Creating self-signed code-signing certificate '$IDENTITY'…"
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
fi

# Trust the certificate for code signing. This edits your certificate trust
# settings, so macOS will ask for your login password once.
echo "▸ Trusting the certificate for code signing (enter your login password if asked)…"
security find-certificate -c "$IDENTITY" -p > "$TMP/leaf.pem"
security add-trusted-cert -r trustRoot -p codeSign "$TMP/leaf.pem"

echo "✓ Done. Now build with:  ./build.sh"
echo "  Grant Screen Recording permission once; it will persist across rebuilds."
