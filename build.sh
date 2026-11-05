#!/bin/bash
# Builds Machine Tile.app. No Xcode project, no Homebrew: Command Line Tools only.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Machine Tile.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
  -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/MachineTile" \
  Sources/*.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Machine Tile</string>
  <key>CFBundleDisplayName</key><string>Machine Tile</string>
  <key>CFBundleIdentifier</key><string>com.machinetile.app</string>
  <key>CFBundleExecutable</key><string>MachineTile</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier com.machinetile.app "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
