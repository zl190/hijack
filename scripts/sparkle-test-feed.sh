#!/bin/sh
# Local test of in-app updates (docs/distribution-spec.md, T3 acceptance 2-4).
# Builds a test app with a high version, zips it into dist-test/, writes an appcast.xml, and prints
# the commands that point the installed Hijack at it. Nothing here touches /Applications or the network.
#
# The appcast entry needs an EdDSA signature from the same key as SUPublicEDKey in the installed app.
# Without the key (generate_keys not run yet) the signature is a placeholder and Sparkle must refuse
# the update; that is acceptance 4. With the key, run sign_update and paste its output; that is
# acceptance 2 and 3.
set -e
cd "$(dirname "$0")/.."
TEST_VERSION="${1:-9.9.9}"
OUT=dist-test
rm -rf "$OUT" && mkdir -p "$OUT"
HIJACK_VERSION="$TEST_VERSION" HIJACK_SIGN_ID="${HIJACK_SIGN_ID:-Hijack Signing}" ./build.sh
ditto -c -k --keepParent build/Hijack.app "$OUT/Hijack.zip"
LENGTH=$(stat -f %z "$OUT/Hijack.zip")
SIG="PLACEHOLDER-run-sign_update"
if [ -x .sparkle/bin/sign_update ] && .sparkle/bin/sign_update "$OUT/Hijack.zip" >"$OUT/sig.txt" 2>/dev/null; then
  SIG=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$OUT/sig.txt")
  echo "signed with the keychain key"
else
  echo "no Sparkle key in the keychain: the signature is a placeholder (acceptance 4 only)"
fi
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Hijack test feed</title>
    <item>
      <title>Hijack $TEST_VERSION (test)</title>
      <sparkle:version>$TEST_VERSION</sparkle:version>
      <sparkle:shortVersionString>$TEST_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>Test build from scripts/sparkle-test-feed.sh. Not a release.</p>]]></description>
      <enclosure url="http://127.0.0.1:8000/Hijack.zip" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIG"/>
    </item>
  </channel>
</rss>
XML
echo
echo "Point the installed app at this feed, then serve it:"
echo "  defaults write com.zl190.hijack SUFeedURL http://127.0.0.1:8000/appcast.xml"
echo "  python3 -m http.server 8000 -d $OUT"
echo "Then choose Check for Updates… in the Hijack menu."
echo "Afterwards: defaults delete com.zl190.hijack SUFeedURL"
