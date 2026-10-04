#!/bin/sh
# Mutation check for review 5, #7: the stale-grant guidance must show whenever Accessibility is not
# trusted, not the other way round. Wraps the existing scripts/mutate-check.sh.
# Usage: scripts/mutate-check-review5-7.sh
set -u
cd "$(dirname "$0")/.."
fail=0

run() {
  scripts/mutate-check.sh "$1" "$2" "$3" || fail=1
}

echo "--- the guidance must show when not trusted, not when trusted ---"
run Sources/Core/MenuState.swift \
  's/public static func showsStaleAccessibilityGuidance(trusted: Bool) -> Bool { !trusted }/public static func showsStaleAccessibilityGuidance(trusted: Bool) -> Bool { trusted }/' \
  MenuStateTests

exit "$fail"
