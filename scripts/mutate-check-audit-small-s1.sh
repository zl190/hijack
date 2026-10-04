#!/bin/sh
# Mutation checks for the audit-small review (docs/review-6/audit-small-review.md), S1: the key-recording
# timeout must notify Settings too (onKeyRecordingTimeout), not only clear Engine.paused. Named
# "audit-small", not "review6": scripts/mutate-check-review6-s*.sh already names an earlier, unrelated
# review (docs/review-6/wave-review.md). Wraps the existing scripts/mutate-check.sh.
# Usage: scripts/mutate-check-audit-small-s1.sh
set -u
cd "$(dirname "$0")/.."
fail=0

run() {
  scripts/mutate-check.sh "$1" "$2" "$3" || fail=1
}

echo "--- the timeout must call onKeyRecordingTimeout ---"
run Sources/Core/Engine.swift \
  's/onKeyRecordingTimeout?()/_ = onKeyRecordingTimeout/' \
  HCIFaultsTests/testKeyRecordingPause_TimeoutCallsOnKeyRecordingTimeout

echo "--- a stale timeout must not call onKeyRecordingTimeout either ---"
run Sources/Core/Engine.swift \
  's/guard token == recordingToken else { return }/guard token != recordingToken else { return }/' \
  HCIFaultsTests/testKeyRecordingPause_StaleTimeoutDoesNotCallOnKeyRecordingTimeout

exit "$fail"
