#!/bin/bash
# Builds ThreadBar.app (menu bar overview of your Claude threads) and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/ThreadBar.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target arm64-apple-macosx14.0 ThreadBar.swift -o "$APP/Contents/MacOS/ThreadBar"
cp ../threads.py "$APP/Contents/Resources/threads.py"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ThreadBar</string>
  <key>CFBundleIdentifier</key><string>local.threadbar</string>
  <key>CFBundleExecutable</key><string>ThreadBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
mkdir -p ~/Applications
rm -rf ~/Applications/ThreadBar.app && cp -R "$APP" ~/Applications/
echo "Built ~/Applications/ThreadBar.app. Open it with: open ~/Applications/ThreadBar.app"
