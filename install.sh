#!/bin/sh
# Install the latest Hijack release:  curl -fsSL https://raw.githubusercontent.com/zl190/hijack/main/install.sh | sh
set -e
[ "$(uname -m)" = arm64 ] || { echo "Hijack needs an Apple silicon Mac."; exit 1; }

# Overrides for scripts/test-install.sh. The defaults are the real public release.
INSTALL_DIR="${HIJACK_INSTALL_DIR:-/Applications}"
RELEASE_URL="${HIJACK_RELEASE_URL:-https://github.com/zl190/hijack/releases/latest/download/}"
EXPECT_AUTHORITY="${HIJACK_EXPECT_AUTHORITY:-Hijack Signing}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "${RELEASE_URL}Hijack.zip" -o "$TMP/Hijack.zip"

if ! curl -fsSL "${RELEASE_URL}Hijack.zip.sha256" -o "$TMP/Hijack.zip.sha256" || [ ! -s "$TMP/Hijack.zip.sha256" ]; then
  echo "checksum file missing from the release: Hijack.zip.sha256 was not found at $RELEASE_URL"
  echo "Nothing was installed. Try again once the release carries a checksum file."
  exit 1
fi

EXPECTED_SUM="$(awk '{print $1}' "$TMP/Hijack.zip.sha256")"
ACTUAL_SUM="$(shasum -a 256 "$TMP/Hijack.zip" | awk '{print $1}')"
if [ "$EXPECTED_SUM" != "$ACTUAL_SUM" ]; then
  echo "Checksum mismatch for Hijack.zip. Nothing was installed."
  echo "  expected: $EXPECTED_SUM"
  echo "  actual:   $ACTUAL_SUM"
  exit 1
fi

ditto -x -k "$TMP/Hijack.zip" "$TMP"
APP="$TMP/Hijack.app"
if [ ! -d "$APP" ]; then
  echo "Hijack.app was not found inside Hijack.zip after unzipping it. Nothing was installed."
  exit 1
fi

if ! VERIFY_ERR="$(codesign --verify --strict --deep "$APP" 2>&1)"; then
  echo "Signature verification failed for Hijack.app. Nothing was installed."
  echo "$VERIFY_ERR"
  exit 1
fi

ACTUAL_AUTHORITY="$(codesign -dv "$APP" 2>&1 | awk -F'=' '/^Authority=/{print $2; exit}')"
if [ -n "${HIJACK_SKIP_AUTHORITY_CHECK:-}" ]; then
  echo "HIJACK_SKIP_AUTHORITY_CHECK is set: skipping the signing-authority check (codesign reports '${ACTUAL_AUTHORITY:-none}')."
elif [ "$ACTUAL_AUTHORITY" != "$EXPECT_AUTHORITY" ]; then
  echo "Signing authority mismatch for Hijack.app. Nothing was installed."
  echo "  expected: $EXPECT_AUTHORITY"
  echo "  actual:   ${ACTUAL_AUTHORITY:-none}"
  exit 1
fi

# A non-default HIJACK_INSTALL_DIR means a test run (scripts/test-install.sh): touch only that temp
# directory, never the real running app or the real ~/.local/bin/hijack link.
if [ "$INSTALL_DIR" = /Applications ]; then
  pkill -x Hijack 2>/dev/null || true
fi
rm -rf "$INSTALL_DIR/Hijack.app"
mkdir -p "$INSTALL_DIR"
mv "$APP" "$INSTALL_DIR/"
xattr -dr com.apple.quarantine "$INSTALL_DIR/Hijack.app" 2>/dev/null || true
# LaunchServices can refuse a launch right after the bundle is replaced (-600/-609) while it re-registers it
for try in 1 2 3; do open "$INSTALL_DIR/Hijack.app" && break; sleep 2; done
if [ "$INSTALL_DIR" = /Applications ]; then
  # the `hijack` command: link it into ~/.local/bin when that's on PATH
  if [ -d "$HOME/.local/bin" ] && echo ":$PATH:" | grep -q ":$HOME/.local/bin:"; then
    ln -sf "$INSTALL_DIR/Hijack.app/Contents/MacOS/Hijack" "$HOME/.local/bin/hijack" && echo "Linked the hijack command into ~/.local/bin"
  else
    echo "For the hijack command: ln -s $INSTALL_DIR/Hijack.app/Contents/MacOS/Hijack <a directory on your PATH>/hijack"
  fi
fi
echo "Hijack installed. Allow it in System Settings > Privacy & Security > Accessibility."
