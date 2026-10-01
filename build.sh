#!/bin/sh
# Build build/Hijack.app (Apple silicon). Needs Xcode Command Line Tools.
# HIJACK_SIGN_ID: signing identity. Releases use one fixed identity so the Accessibility
# grant survives updates; unset = ad-hoc (re-grant after every build).
set -e
cd "$(dirname "$0")"
VERSION="${HIJACK_VERSION:-$(cat VERSION)}"
APP=build/Hijack.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target arm64-apple-macos13 Sources/*.swift -o "$APP/Contents/MacOS/Hijack"
ICONSET="$(mktemp -d)/Hijack.iconset"; mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz assets/Hijack-1024.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz*2)) $((sz*2)) assets/Hijack-1024.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Hijack.icns"
cp assets/HijackMenuTemplate.png "assets/HijackMenuTemplate@2x.png" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.zl190.hijack</string>
  <key>CFBundleName</key><string>Hijack</string>
  <key>CFBundleExecutable</key><string>Hijack</string>
  <key>CFBundleIconFile</key><string>Hijack</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign "${HIJACK_SIGN_ID:--}" "$APP"
echo "built $APP $VERSION"
