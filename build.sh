#!/bin/sh
# Build build/Hijack.app (Apple silicon). Needs Xcode Command Line Tools. The binary is built by SwiftPM.
# HIJACK_SIGN_ID: signing identity. Releases use one fixed identity so the Accessibility
# grant survives updates; unset = ad-hoc (re-grant after every build).
set -e
cd "$(dirname "$0")"
VERSION="${HIJACK_VERSION:-$(cat VERSION)}"
# CFBundleVersion stays plain VERSION (review-4 M2): generate_appcast copies it into sparkle:version, and
# Sparkle's SUStandardVersionComparator orders two builds of the SAME VERSION by the sha's characters, not
# by recency — a real risk now that Sparkle is wired up on this branch. The build identity (sha, +dirty
# when the tree has uncommitted changes) goes in the custom HijackCommit key instead; `hijack version` and
# `hijack status` print it next to VERSION. `make release` builds at a clean tag, so a release's
# HijackCommit is always clean.
GIT_SHA="$(git rev-parse --short=7 HEAD 2>/dev/null || true)"
if [ -n "$GIT_SHA" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then GIT_SHA="${GIT_SHA}+dirty"; fi
HIJACK_COMMIT="${GIT_SHA:-unknown}"
APP=build/Hijack.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Sparkle (in-app updates): scripts/fetch-sparkle.sh keeps .sparkle/<version>/ (pinned by sha256).
# Package.swift links the framework from there; the app embeds it below. The XPC services are for
# sandboxed apps only; Hijack is not sandboxed, so they are not copied.
scripts/fetch-sparkle.sh
SPARKLE_DIR="$(scripts/fetch-sparkle.sh --print-dir)"
# The binary comes from SwiftPM (Package.swift: targets HijackCore and Hijack). build.sh assembles the bundle.
swift build -c release --product Hijack
cp "$(swift build -c release --show-bin-path)/Hijack" "$APP/Contents/MacOS/Hijack"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
# The public key for update signatures. generate_keys prints it once; the placeholder makes every update fail its check.
# With the placeholder the key is left out of Info.plist: Sparkle would refuse to start and show an alert on every launch.
SPARKLE_PUBKEY="${HIJACK_SPARKLE_PUBKEY:-$(cat assets/sparkle-public-key.txt)}"
SPARKLE_KEY_PLIST="  <key>SUPublicEDKey</key><string>$SPARKLE_PUBKEY</string>"
case "$SPARKLE_PUBKEY" in REPLACE-*)
  echo "warning: assets/sparkle-public-key.txt is the placeholder; this build has no in-app updates"
  SPARKLE_KEY_PLIST="" ;;
esac
# App icon: the layered Icon Composer icon (Liquid Glass, Default/Dark/Clear/Tinted) needs Xcode's actool,
# which also writes a flat Hijack.icns for older macOS. When actool is absent or fails (a CI runner
# whose actool cannot read the .icon format), the flat icon comes from the PNG instead.
flat_icon() {
  ICONSET="$(mktemp -d)/Hijack.iconset"; mkdir -p "$ICONSET"
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz assets/Hijack-1024.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
    sips -z $((sz*2)) $((sz*2)) assets/Hijack-1024.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Hijack.icns"
}
if xcrun --find actool >/dev/null 2>&1 && xcrun actool assets/Hijack.icon --compile "$APP/Contents/Resources"     --app-icon Hijack --platform macosx --minimum-deployment-target 13.0 --target-device mac     --output-partial-info-plist /dev/null >/dev/null 2>&1 && [ -f "$APP/Contents/Resources/Hijack.icns" ]; then
  :
else
  echo "actool unavailable or failed: using the flat icon from assets/Hijack-1024.png"
  flat_icon
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
  <key>HijackCommit</key><string>$HIJACK_COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>SUFeedURL</key><string>https://github.com/zl190/hijack/releases/latest/download/appcast.xml</string>
$SPARKLE_KEY_PLIST
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict></plist>
PLIST
# codesign re-signs the framework itself with the app identity. Autoupdate and Updater.app inside it keep
# Sparkle's own signature; they run as separate processes and are not checked against the app's identity.
codesign --force --sign "${HIJACK_SIGN_ID:--}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "${HIJACK_SIGN_ID:--}" "$APP"
echo "built $APP $VERSION (commit $HIJACK_COMMIT)"
