#!/bin/sh
# Build from source and install to /Applications. Needs Xcode Command Line Tools (xcode-select --install).
set -e
cd "$(dirname "$0")"
./build.sh
pkill -x Hijack 2>/dev/null || true
rm -rf /Applications/Hijack.app
cp -R build/Hijack.app /Applications/
open /Applications/Hijack.app
echo "Hijack installed. Allow it in System Settings > Privacy & Security > Accessibility."
