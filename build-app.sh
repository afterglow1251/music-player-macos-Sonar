#!/bin/bash
# Builds Sonar as a release binary and wraps it in a double-clickable macOS
# .app bundle. Output: ./Sonar.app (drag it into /Applications).
#
#   ./build-app.sh          → a dev build, versioned 0.0.0
#   ./build-app.sh 0.3.0    → stamps 0.3.0 into the bundle (what release.sh does)
set -euo pipefail

cd "$(dirname "$0")"

APP="Sonar.app"
BIN_NAME="Sonar"
# The version the bundle reports. Releases pass it in; a bare dev build gets
# 0.0.0 rather than a number that could be mistaken for a shipped one.
VERSION="0.0.0"
[ $# -gt 0 ] && VERSION="${1#v}"

echo "▶ Building release binary…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$BIN_NAME"
[ -x "$BIN_PATH" ] || { echo "✗ binary not found at $BIN_PATH"; exit 1; }

echo "▶ Assembling ${APP} (${VERSION})…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"

echo "▶ Generating app icon…"
swiftc Tools/main.swift Sources/Sonar/AppIcon.swift -o .build/make-icon
.build/make-icon
iconutil -c icns Sonar.iconset -o "$APP/Contents/Resources/Sonar.icns"
rm -rf Sonar.iconset

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Sonar</string>
    <key>CFBundleDisplayName</key>     <string>Sonar</string>
    <key>CFBundleIdentifier</key>      <string>com.afterglow.sonar</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>Sonar</string>
    <key>CFBundleIconFile</key>        <string>Sonar</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc code signature so Gatekeeper lets it run locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ Built $APP"
echo "  Move it to Applications:  cp -R $APP /Applications/"
echo "  Or open it now:           open $APP"
