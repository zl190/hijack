#!/bin/sh
# Build build/Hijack.app (Apple silicon). Needs Xcode Command Line Tools.
# HIJACK_SIGN_ID: signing identity. Releases use one fixed identity so the Accessibility
# grant survives updates; unset = ad-hoc (re-grant after every build).
set -e
cd "$(dirname "$0")"
VERSION="${HIJACK_VERSION:-$(cat VERSION)}"
APP=build/Hijack.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target arm64-apple-macos13 Sources/*.swift Sources/Core/*.swift -o "$APP/Contents/MacOS/Hijack"
# App icon: the layered Icon Composer icon (Liquid Glass, Default/Dark/Clear/Tinted) needs Xcode's actool,
# which also writes a flat Hijack.icns for older macOS. Command Line Tools alone: flat icon from the PNG.
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool assets/Hijack.icon --compile "$APP/Contents/Resources" --app-icon Hijack --platform macosx \
    --minimum-deployment-target 13.0 --target-device mac --output-partial-info-plist /dev/null >/dev/null
else
  ICONSET="$(mktemp -d)/Hijack.iconset"; mkdir -p "$ICONSET"
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz assets/Hijack-1024.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
    sips -z $((sz*2)) $((sz*2)) assets/Hijack-1024.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Hijack.icns"
fi
mkdir -p "$APP/Contents/Library/LaunchAgents" && cp assets/com.zl190.hijack.relauncher.plist "$APP/Contents/Library/LaunchAgents/"
cp assets/HijackMenuTemplate.png assets/HijackMenuTemplate@2x.png assets/HijackMenuTemplate-Off.png assets/HijackMenuTemplate-Off@2x.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.zl190.hijack</string>
  <key>CFBundleName</key><string>Hijack</string>
  <key>CFBundleExecutable</key><string>Hijack</string>
  <key>CFBundleIconFile</key><string>Hijack</string>
  <key>CFBundleIconName</key><string>Hijack</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign "${HIJACK_SIGN_ID:--}" "$APP"
echo "built $APP $VERSION"
