#!/bin/sh
# Build build/Hijack.app (Apple silicon). Needs Xcode Command Line Tools.
# HIJACK_SIGN_ID: signing identity. Releases use one fixed identity so the Accessibility
# grant survives updates; unset = ad-hoc (re-grant after every build).
set -e
cd "$(dirname "$0")"
VERSION="${HIJACK_VERSION:-$(cat VERSION)}"
APP=build/Hijack.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Sparkle (in-app updates), pinned by sha256. The framework is linked by swiftc and embedded in the app.
# The XPC services are for sandboxed apps only; Hijack is not sandboxed, so they are not copied.
SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
SPARKLE_DIR=.sparkle
SPARKLE_TAR="$SPARKLE_DIR/Sparkle-$SPARKLE_VERSION.tar.xz"
if [ ! -d "$SPARKLE_DIR/Sparkle.framework" ]; then
  mkdir -p "$SPARKLE_DIR"
  [ -f "$SPARKLE_TAR" ] || curl -fsSL -o "$SPARKLE_TAR" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  echo "$SPARKLE_SHA256  $SPARKLE_TAR" | shasum -a 256 -c - >/dev/null || { echo "Sparkle download does not match the pinned sha256"; exit 1; }
  tar -xJf "$SPARKLE_TAR" -C "$SPARKLE_DIR" Sparkle.framework bin
fi
swiftc -O -target arm64-apple-macos13 -F "$SPARKLE_DIR" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  Sources/*.swift Sources/Core/*.swift -o "$APP/Contents/MacOS/Hijack"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
# The public key for update signatures. generate_keys prints it once; the placeholder makes every update fail its check.
SPARKLE_PUBKEY="${HIJACK_SPARKLE_PUBKEY:-$(cat assets/sparkle-public-key.txt)}"
case "$SPARKLE_PUBKEY" in REPLACE-*) echo "warning: assets/sparkle-public-key.txt is the placeholder; in-app updates will not verify" ;; esac
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
  <key>SUFeedURL</key><string>https://github.com/zl190/hijack/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBKEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict></plist>
PLIST
# The framework is signed first, with the same identity as the app, so that --deep verification passes.
codesign --force --sign "${HIJACK_SIGN_ID:--}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "${HIJACK_SIGN_ID:--}" "$APP"
echo "built $APP $VERSION"
