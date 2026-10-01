#!/bin/sh
# Maintainer: build, zip, publish a GitHub release, print the cask sha256.
# Needs the "Hijack Signing" identity in the login keychain (keeps users' Accessibility grant across updates).
set -e
cd "$(dirname "$0")"
VERSION="$(cat VERSION)"
HIJACK_SIGN_ID="Hijack Signing" ./build.sh
ditto -c -k --keepParent build/Hijack.app build/Hijack.zip
gh release create "v$VERSION" build/Hijack.zip --title "Hijack $VERSION" --notes "Hijack $VERSION"
shasum -a 256 build/Hijack.zip
