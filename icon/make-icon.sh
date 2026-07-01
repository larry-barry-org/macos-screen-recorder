#!/bin/bash
# Generates Resources/AppIcon.icns from icon/generate-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ Rendering 1024×1024 base image…"
swift icon/generate-icon.swift "$TMP/icon-1024.png"

echo "▸ Building iconset…"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$TMP/icon-1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
    sips -z "$double" "$double" "$TMP/icon-1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

mkdir -p Resources
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "✓ Wrote Resources/AppIcon.icns"
