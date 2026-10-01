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
# LaunchServices can refuse a launch right after the bundle is replaced (-600/-609) while it re-registers it
for try in 1 2 3; do open /Applications/Hijack.app && break; sleep 2; done
# the `hijack` command: link it into ~/.local/bin when that's on PATH
if [ -d "$HOME/.local/bin" ] && echo ":$PATH:" | grep -q ":$HOME/.local/bin:"; then
  ln -sf /Applications/Hijack.app/Contents/MacOS/Hijack "$HOME/.local/bin/hijack" && echo "Linked the hijack command into ~/.local/bin"
else
  echo "For the hijack command: ln -s /Applications/Hijack.app/Contents/MacOS/Hijack <a directory on your PATH>/hijack"
fi
echo "Hijack installed. Allow it in System Settings > Privacy & Security > Accessibility."
