#!/bin/sh
# Mutation harness for install.sh (W4, docs/engineering-wave-spec.md §3).
# Serves a locally built Hijack.zip and its checksum over python3 -m http.server, then runs install.sh
# against four inputs: a good zip with a good checksum, a tampered zip, a release with no checksum file,
# and a zip whose checksum is correct but whose signed contents are not. Never touches /Applications and
# never kills the real running Hijack: HIJACK_INSTALL_DIR always points at a temp dir here, and install.sh
# only pkills Hijack when HIJACK_INSTALL_DIR is exactly /Applications.
set -u
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

WORK="$(mktemp -d)"
SERVER_PIDS=""
cleanup() {
  for pid in $SERVER_PIDS; do kill "$pid" 2>/dev/null || true; done
  # the test installs into $WORK/install_dir_*; kill only Hijack binaries that `open` launched from there.
  pkill -f "$WORK/install_dir_" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok()   { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

serve() {
  # serve <dir> -> prints the port, appends the server pid to SERVER_PIDS
  dir="$1"
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  ( cd "$dir" && exec python3 -m http.server "$port" --bind 127.0.0.1 >"$WORK/httpd-$port.log" 2>&1 ) &
  SERVER_PIDS="$SERVER_PIDS $!"
  for _ in $(seq 1 50); do
    curl -fsS "http://127.0.0.1:$port/Hijack.zip" >/dev/null 2>&1 && break
    sleep 0.1
  done
  echo "$port"
}

echo "== building a local dev app (ad-hoc signature) =="
if ! make -C "$ROOT" build >"$WORK/build.log" 2>&1; then
  cat "$WORK/build.log"
  echo "make build failed"
  exit 1
fi

GOOD="$WORK/serve_good"
mkdir -p "$GOOD"
ditto -c -k --keepParent "$ROOT/build/Hijack.app" "$GOOD/Hijack.zip"
shasum -a 256 "$GOOD/Hijack.zip" | awk '{print $1 "  Hijack.zip"}' > "$GOOD/Hijack.zip.sha256"

# the dev build is ad-hoc, so it has no Authority= line; case (a) matches HIJACK_EXPECT_AUTHORITY to
# whatever this build actually reports, instead of the release identity "Hijack Signing".
DEV_AUTHORITY="$(codesign -dv "$ROOT/build/Hijack.app" 2>&1 | awk -F'=' '/^Authority=/{print $2; exit}')"
if [ -z "$DEV_AUTHORITY" ]; then
  echo "dev build is ad-hoc (no Authority= line); case (a) skips the authority check via HIJACK_SKIP_AUTHORITY_CHECK and says so"
fi

echo
echo "== case (a): good zip, good checksum -> installs =="
PORT_A="$(serve "$GOOD")"
INSTALL_A="$WORK/install_dir_a"
mkdir -p "$INSTALL_A"
if [ -n "$DEV_AUTHORITY" ]; then
  HIJACK_INSTALL_DIR="$INSTALL_A" HIJACK_RELEASE_URL="http://127.0.0.1:$PORT_A/" \
    HIJACK_EXPECT_AUTHORITY="$DEV_AUTHORITY" sh "$ROOT/install.sh" >"$WORK/a.log" 2>&1
  RC_A=$?
else
  HIJACK_INSTALL_DIR="$INSTALL_A" HIJACK_RELEASE_URL="http://127.0.0.1:$PORT_A/" \
    HIJACK_SKIP_AUTHORITY_CHECK=1 sh "$ROOT/install.sh" >"$WORK/a.log" 2>&1
  RC_A=$?
fi
cat "$WORK/a.log"
if [ "$RC_A" -eq 0 ] && [ -d "$INSTALL_A/Hijack.app" ]; then
  ok "good zip + good checksum installs the app"
else
  fail "good zip + good checksum did not install the app (exit $RC_A)"
fi
pkill -f "$INSTALL_A/Hijack.app/Contents/MacOS/Hijack" 2>/dev/null || true

echo
echo "== case (b): tampered zip (one byte appended), checksum file unchanged -> refused =="
BAD="$WORK/serve_bad"
mkdir -p "$BAD"
cp "$GOOD/Hijack.zip" "$BAD/Hijack.zip"
cp "$GOOD/Hijack.zip.sha256" "$BAD/Hijack.zip.sha256"
printf 'x' >> "$BAD/Hijack.zip"
PORT_B="$(serve "$BAD")"
INSTALL_B="$WORK/install_dir_b"
mkdir -p "$INSTALL_B"
HIJACK_INSTALL_DIR="$INSTALL_B" HIJACK_RELEASE_URL="http://127.0.0.1:$PORT_B/" HIJACK_SKIP_AUTHORITY_CHECK=1 \
  sh "$ROOT/install.sh" >"$WORK/b.log" 2>&1
RC_B=$?
cat "$WORK/b.log"
if [ "$RC_B" -ne 0 ] && grep -q "Checksum mismatch" "$WORK/b.log" && [ ! -e "$INSTALL_B/Hijack.app" ]; then
  ok "tampered zip is refused with the checksum-mismatch message, nothing installed"
else
  fail "tampered zip was not refused the right way (exit $RC_B)"
fi

echo
echo "== case (c): checksum file missing from the release -> refused with a clear message =="
NOSUM="$WORK/serve_nosum"
mkdir -p "$NOSUM"
cp "$GOOD/Hijack.zip" "$NOSUM/Hijack.zip"
PORT_C="$(serve "$NOSUM")"
INSTALL_C="$WORK/install_dir_c"
mkdir -p "$INSTALL_C"
HIJACK_INSTALL_DIR="$INSTALL_C" HIJACK_RELEASE_URL="http://127.0.0.1:$PORT_C/" \
  sh "$ROOT/install.sh" >"$WORK/c.log" 2>&1
RC_C=$?
cat "$WORK/c.log"
if [ "$RC_C" -ne 0 ] && grep -q "checksum file missing from the release" "$WORK/c.log" && [ ! -e "$INSTALL_C/Hijack.app" ]; then
  ok "missing checksum file is refused with the clear message, nothing installed"
else
  fail "missing checksum file was not refused the right way (exit $RC_C)"
fi

echo
echo "== case (d): checksum is correct, but the signed contents are not -> refused =="
CORRUPT_BUILD="$WORK/corrupt_build"
mkdir -p "$CORRUPT_BUILD"
ditto -x -k "$GOOD/Hijack.zip" "$CORRUPT_BUILD"
# flip one byte of a sealed resource: the zip's own bytes (and so its checksum) are whatever we zip next,
# but codesign --verify must now fail because the sealed resource no longer matches its recorded hash.
printf '\000' | dd of="$CORRUPT_BUILD/Hijack.app/Contents/Resources/HijackMenuTemplate.png" bs=1 seek=4 count=1 conv=notrunc 2>/dev/null
BADSIG="$WORK/serve_badsig"
mkdir -p "$BADSIG"
ditto -c -k --keepParent "$CORRUPT_BUILD/Hijack.app" "$BADSIG/Hijack.zip"
shasum -a 256 "$BADSIG/Hijack.zip" | awk '{print $1 "  Hijack.zip"}' > "$BADSIG/Hijack.zip.sha256"
PORT_D="$(serve "$BADSIG")"
INSTALL_D="$WORK/install_dir_d"
mkdir -p "$INSTALL_D"
HIJACK_INSTALL_DIR="$INSTALL_D" HIJACK_RELEASE_URL="http://127.0.0.1:$PORT_D/" HIJACK_SKIP_AUTHORITY_CHECK=1 \
  sh "$ROOT/install.sh" >"$WORK/d.log" 2>&1
RC_D=$?
cat "$WORK/d.log"
if [ "$RC_D" -ne 0 ] && grep -q "Signature verification failed" "$WORK/d.log" && [ ! -e "$INSTALL_D/Hijack.app" ]; then
  ok "a correct checksum with a broken signature is refused, nothing installed"
else
  fail "the broken-signature zip was not refused the right way (exit $RC_D)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
