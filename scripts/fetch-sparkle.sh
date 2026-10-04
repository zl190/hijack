#!/bin/sh
# Download Sparkle into .sparkle/<version>/, pinned by sha256. The package links the framework from there,
# so `swift build` and `swift test` both need it. Idempotent: a complete cache is left alone.
# The download and the extraction land under a temporary name and move into place only when complete,
# so a stopped run never leaves a half cache that the next run trusts.
set -e
cd "$(dirname "$0")/.."
SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
SPARKLE_DIR=".sparkle/$SPARKLE_VERSION"
if [ "$1" = "--print-dir" ]; then echo "$SPARKLE_DIR"; exit 0; fi
if [ "$1" = "--print-version" ]; then echo "$SPARKLE_VERSION"; exit 0; fi
if [ -d "$SPARKLE_DIR/Sparkle.framework" ] && [ -x "$SPARKLE_DIR/bin/generate_appcast" ]; then exit 0; fi
rm -rf "$SPARKLE_DIR" "$SPARKLE_DIR.part"; mkdir -p "$SPARKLE_DIR.part"
SPARKLE_TAR="$SPARKLE_DIR.part/Sparkle-$SPARKLE_VERSION.tar.xz"
curl -fsSL -o "$SPARKLE_TAR" \
  "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
echo "$SPARKLE_SHA256  $SPARKLE_TAR" | shasum -a 256 -c - >/dev/null \
  || { rm -rf "$SPARKLE_DIR.part"; echo "Sparkle $SPARKLE_VERSION download does not match the pinned sha256; nothing was kept"; exit 1; }
tar -xJf "$SPARKLE_TAR" -C "$SPARKLE_DIR.part" Sparkle.framework bin
rm "$SPARKLE_TAR"
mv "$SPARKLE_DIR.part" "$SPARKLE_DIR"
echo "Sparkle $SPARKLE_VERSION ready in $SPARKLE_DIR"
