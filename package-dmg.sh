#!/bin/bash
# Packages build/ScreenRecorder.app into a distributable DMG with an
# /Applications shortcut for drag-to-install. Run ./build.sh first.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/ScreenRecorder.app"
DMG="build/ScreenRecorder.dmg"
VOL="Screen Recorder"

[ -d "$APP" ] || { echo "✗ $APP not found — run ./build.sh first."; exit 1; }

echo "▸ Staging DMG contents…"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "▸ Creating ${DMG}…"
rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "✓ Built $DMG"
