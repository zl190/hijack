#!/bin/sh
# Mutation check for the SwiftPM build (docs/engineering-wave-spec.md W1).
# (a) The executable target points at a wrong folder: `make build` must fail.
# (b) The Sparkle search path is removed from the compiler flags: `import Sparkle` must fail.
# Then both are restored and `make build` must pass. Exit 1 on any unexpected result.
set -u
cd "$(dirname "$0")/.."
cp Package.swift Package.swift.orig
restore() { mv Package.swift.orig Package.swift; }
trap restore EXIT
fail=0
sed -i '' 's|path: "Sources/App"|path: "Sources/Nowhere"|' Package.swift
if make build >/dev/null 2>&1; then echo "(a) wrong target path: build PASSED, expected FAIL"; fail=1; else echo "(a) wrong target path: build fails as expected"; fi
cp Package.swift.orig Package.swift
sed -i '' 's|swiftSettings: \[.unsafeFlags(\["-F", sparkleDir\])\],||' Package.swift
if make build >/dev/null 2>&1; then echo "(b) no Sparkle search path: build PASSED, expected FAIL"; fail=1; else echo "(b) no Sparkle search path: compile fails as expected"; fi
cp Package.swift.orig Package.swift
if make build >/dev/null 2>&1; then echo "(restore) build passes"; else echo "(restore) build FAILED"; fail=1; fi
exit $fail
