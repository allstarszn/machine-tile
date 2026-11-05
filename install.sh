#!/bin/bash
# Installs Machine Tile to ~/Applications and starts it at login.
set -euo pipefail
cd "$(dirname "$0")"

DEST="$HOME/Applications/Machine Tile.app"
LABEL="com.machinetile.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

./build.sh

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
sleep 1

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
cp -R "build/Machine Tile.app" "$DEST"
codesign --force --sign - --identifier "$LABEL" "$DEST" >/dev/null 2>&1 || true

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>Program</key><string>$DEST/Contents/MacOS/MachineTile</string>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLISTEOF

launchctl bootstrap "gui/$UID" "$PLIST"

echo
echo "Installed to $DEST"
echo "Look for the gauge icon in your menu bar."
