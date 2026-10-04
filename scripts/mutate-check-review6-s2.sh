#!/bin/sh
# Mutation check for review 6, S2: the "newer than start" boundary must be strict (>), not >=.
# Wraps the existing scripts/mutate-check.sh.
# Usage: scripts/mutate-check-review6-s2.sh
set -u
cd "$(dirname "$0")/.."
fail=0

run() {
  scripts/mutate-check.sh "$1" "$2" "$3" || fail=1
}

echo "--- an equal timestamp must not read as newer ---"
run Sources/Core/MetricsSummary.swift \
  's/return lastCrash > startedAt/return lastCrash >= startedAt/' \
  MetricsSummaryTests/testACrashAtExactlyStartIsNotNewerThanStart

exit "$fail"
