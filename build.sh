#!/bin/bash
# Build the get_iplayer GUI as a native macOS app bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="get_iplayer_gui"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# Clean any previous build so stale files don't persist.
rm -rf "$APP_BUNDLE"

echo "Compiling Swift sources..."
mkdir -p "$MACOS" "$RESOURCES"

swiftc -O \
  -target arm64-apple-macosx13.0 \
  -o "$MACOS/$APP_NAME" \
  GetIPlayerGUI.swift

# Info.plist
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>get_iplayer GUI</string>
    <key>CFBundleDisplayName</key>
    <string>get_iplayer GUI</string>
    <key>CFBundleIdentifier</key>
    <string>local.getiplayer.gui</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>get_iplayer_gui</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# The app references the get_iplayer binary installed at /usr/local/bin/get_iplayer,
# so no binary is bundled here.

# Ad-hoc sign the bundle so it can be launched with `open`.
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "Built: $APP_BUNDLE"
