#!/bin/sh
# Install the latest Hijack release:  curl -fsSL https://raw.githubusercontent.com/zl190/hijack/main/install.sh | sh
set -e
[ "$(uname -m)" = arm64 ] || { echo "Hijack needs an Apple silicon Mac."; exit 1; }
TMP="$(mktemp -d)"
curl -fsSL https://github.com/zl190/hijack/releases/latest/download/Hijack.zip -o "$TMP/Hijack.zip"
ditto -x -k "$TMP/Hijack.zip" "$TMP"
pkill -x Hijack 2>/dev/null || true
rm -rf /Applications/Hijack.app
mv "$TMP/Hijack.app" /Applications/
xattr -dr com.apple.quarantine /Applications/Hijack.app 2>/dev/null || true
open /Applications/Hijack.app
echo "Hijack installed. Allow it in System Settings > Privacy & Security > Accessibility."
