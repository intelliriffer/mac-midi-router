#!/bin/sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --scratch-path build

APP="build/mac-midi-router.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp build/release/MidiRouterApp "$APP/Contents/MacOS/mac-midi-router"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>mac-midi-router</string>
    <key>CFBundleIdentifier</key><string>local.mac-midi-router</string>
    <key>CFBundleExecutable</key><string>mac-midi-router</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force -s - "$APP"
echo "Built $APP"
