#!/bin/sh
# Build Hijack.app into /Applications and open it. Needs Xcode Command Line Tools (xcode-select --install).
set -e
cd "$(dirname "$0")"
APP=/Applications/Hijack.app
BIN="$(mktemp -d)/Hijack"
swiftc -O Hijack.swift -o "$BIN"          # build first: a failed build leaves the installed app alone
pkill -x Hijack 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BIN" "$APP/Contents/MacOS/Hijack"
# icons: app icon (.icns from the 1024 master) + menu bar template
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
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
# A fixed identity keeps the Accessibility grant across rebuilds; default ad-hoc means re-granting after each build.
codesign --force --sign "${HIJACK_SIGN_ID:--}" "$APP"
open "$APP"
echo "Hijack installed."
