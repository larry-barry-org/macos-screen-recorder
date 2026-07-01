#!/bin/bash
# Builds ScreenRecorder.app: compiles with SwiftPM, assembles the .app bundle,
# and code-signs it. If the "ScreenRecorder Dev" identity exists (run ./setup.sh
# first) it signs with that stable identity so the Screen Recording permission
# survives rebuilds; otherwise it falls back to an ad-hoc signature.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="release"
APP="build/ScreenRecorder.app"
IDENTITY="ScreenRecorder Dev"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/ScreenRecorder"

echo "▸ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ScreenRecorder"
cp Info.plist "$APP/Contents/Info.plist"

if security find-identity -p codesigning | grep -q "$IDENTITY"; then
    echo "▸ Code signing with '$IDENTITY'…"
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "▸ Code signing (ad-hoc — run ./setup.sh for a stable identity)…"
    codesign --force --sign - "$APP"
fi

echo "✓ Built $APP"
echo "  Run it with:  open $APP"
