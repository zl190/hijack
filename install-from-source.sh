#!/bin/sh
# Build from source and install to /Applications. Needs Xcode Command Line Tools (xcode-select --install).
set -e
cd "$(dirname "$0")"
./build.sh
pkill -x Hijack 2>/dev/null || true
rm -rf /Applications/Hijack.app
cp -R build/Hijack.app /Applications/
# LaunchServices can refuse a launch right after the bundle is replaced (-600/-609) while it re-registers it
for try in 1 2 3; do open /Applications/Hijack.app && break; sleep 2; done
# the `hijack` command: link it into ~/.local/bin when that's on PATH
if [ -d "$HOME/.local/bin" ] && echo ":$PATH:" | grep -q ":$HOME/.local/bin:"; then
  ln -sf /Applications/Hijack.app/Contents/MacOS/Hijack "$HOME/.local/bin/hijack" && echo "Linked the hijack command into ~/.local/bin"
else
  echo "For the hijack command: ln -s /Applications/Hijack.app/Contents/MacOS/Hijack <a directory on your PATH>/hijack"
fi
echo "Hijack installed. Allow it in System Settings > Privacy & Security > Accessibility."
