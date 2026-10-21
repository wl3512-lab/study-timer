#!/bin/zsh
# Builds StudyTimerBar.app next to this script.
set -euo pipefail
cd "${0:A:h}"

APP=StudyTimerBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"

# Universal binary (Apple Silicon + Intel) that runs on macOS 13 and later.
TMP=$(mktemp -d)
swiftc -O -swift-version 5 -target arm64-apple-macos13 StudyTimerBar.swift -o "$TMP/arm64"
swiftc -O -swift-version 5 -target x86_64-apple-macos13 StudyTimerBar.swift -o "$TMP/x86_64"
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$APP/Contents/MacOS/StudyTimerBar"
rm -rf "$TMP"

# Syne, DM Sans and Space Mono (SIL Open Font License, see fonts/OFL-*.txt).
cp fonts/*.ttf "$APP/Contents/Resources/Fonts/"

# The 8 notification pictures (drawn for Study Timer).
mkdir -p "$APP/Contents/Resources/Pictures"
cp pictures/*.png "$APP/Contents/Resources/Pictures/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Study Timer</string>
  <key>CFBundleIdentifier</key><string>com.braxtonhauw.studytimerbar</string>
  <key>CFBundleExecutable</key><string>StudyTimerBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.1</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Study Timer can play your playlist and pause Spotify during breaks.</string>
</dict>
</plist>
PLIST

xattr -cr "$APP"   # Finder/iCloud metadata breaks codesign
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
