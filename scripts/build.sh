#!/bin/zsh
# Builds "build/Open Play Sync.app" (ad-hoc signed).
# Usage: ./scripts/build.sh [--install]   (--install copies it to /Applications and launches it)
set -e
cd "$(dirname "$0")/.."
APP_NAME="Open Play Sync"
APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.couralabs.openplaysync</string>
<key>CFBundleName</key><string>Open Play Sync</string>
<key>CFBundleDisplayName</key><string>Open Play Sync</string>
<key>CFBundleExecutable</key><string>OpenPlaySync</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>LSUIElement</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>OpenPlaySync captures system audio to play it on all the sound devices you select, in sync.</string>
</dict></plist>
PL
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.2 Sources/main.swift -o "$APP/Contents/MacOS/OpenPlaySync"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "$1" == "--install" ]]; then
  pkill -x OpenPlaySync 2>/dev/null && sleep 1 || true
  rm -rf "/Applications/$APP_NAME.app" ~/Applications/OpenPlaySync.app
  cp -R "$APP" /Applications/
  # Register with Launch Services so Finder, Spotlight and Launchpad pick it up
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
  echo "Installed to /Applications/$APP_NAME.app"
fi
