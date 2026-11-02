#!/bin/bash
# Build Taccuino and create a self-contained .app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"

# With Command Line Tools only, the newest SDK uses SwiftUI macros that
# require a plugin shipped with Xcode only. In that case use SDK 26.5.
SDK_ARGS=()
if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
        SDK_ARGS=(--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)
    elif [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk" ]; then
        SDK_ARGS=(--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk)
    fi
fi

echo "▸ Build ($CONFIG)…"
swift build -c "$CONFIG" "${SDK_ARGS[@]}"

BIN="$(swift build -c "$CONFIG" "${SDK_ARGS[@]}" --show-bin-path)/Taccuino"
APP="$ROOT/dist/Taccuino.app"

echo "▸ Creating the app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Taccuino"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

if [ -d "$ROOT/Resources/Fonts" ]; then
    cp -R "$ROOT/Resources/Fonts" "$APP/Contents/Resources/Fonts"
fi

for lproj in "$ROOT"/Resources/*.lproj; do
    if [ -d "$lproj" ]; then
        cp -R "$lproj" "$APP/Contents/Resources/"
    fi
done

# Ad-hoc signature: required to run the app locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
touch "$APP"

echo "✓ Created: $APP"
echo "  Open with: open \"$APP\""
