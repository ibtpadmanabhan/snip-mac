#!/bin/zsh
# Builds Snip.app (no Xcode needed). Usage: ./build.sh [install]
set -e
cd "$(dirname "$0")"
APP=Snip.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift -o "$APP/Contents/MacOS/Snip" -framework Cocoa -framework Carbon
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.local.snip</string>
  <key>CFBundleName</key><string>Snip</string>
  <key>CFBundleExecutable</key><string>Snip</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>Snip captures the screen area you select.</string>
</dict></plist>
EOF
codesign --force --sign - -r="designated => identifier \"com.local.snip\"" "$APP"
echo "Built $PWD/$APP"
if [[ "$1" == "install" ]]; then
  rm -rf /Applications/Snip.app && cp -R "$APP" /Applications/ && echo "Installed to /Applications/Snip.app"
fi
