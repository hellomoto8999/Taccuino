#!/bin/bash
# Generate Resources/AppIcon.icns by drawing the icon with AppKit.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swift "$ROOT/scripts/make-icon.swift" "$TMP/icon_1024.png"
mkdir -p "$TMP/AppIcon.iconset"
for s in 16 32 64 128 256 512 1024; do
    sips -z "$s" "$s" "$TMP/icon_1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
done
# Names required by iconutil for the @2x variants.
cp "$TMP/AppIcon.iconset/icon_32x32.png"  "$TMP/AppIcon.iconset/icon_16x16@2x.png"
cp "$TMP/AppIcon.iconset/icon_64x64.png"  "$TMP/AppIcon.iconset/icon_32x32@2x.png"
cp "$TMP/AppIcon.iconset/icon_256x256.png" "$TMP/AppIcon.iconset/icon_128x128@2x.png"
cp "$TMP/AppIcon.iconset/icon_512x512.png" "$TMP/AppIcon.iconset/icon_256x256@2x.png"
cp "$TMP/AppIcon.iconset/icon_1024x1024.png" "$TMP/AppIcon.iconset/icon_512x512@2x.png"

mkdir -p Resources
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
echo "✓ Resources/AppIcon.icns"
