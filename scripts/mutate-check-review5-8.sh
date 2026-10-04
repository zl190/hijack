#!/bin/sh
# Mutation checks for review 5, #8: the key-recording pause must clear after 30s, and a stale timeout
# from an earlier, already-finished recording must not cancel a later one's pause. Wraps scripts/mutate-check.sh.
# Usage: scripts/mutate-check-review5-8.sh
set -u
cd "$(dirname "$0")/.."
fail=0

run() {
  scripts/mutate-check.sh "$1" "$2" "$3" || fail=1
}

echo "--- the pause must clear at 30s, not later ---"
run Sources/Core/Engine.swift \
  's/public static let recordingPauseTimeout = 30.0/public static let recordingPauseTimeout = 300.0/' \
  HCIFaultsTests/testKeyRecordingPause_ClearsAt30Seconds

echo "--- a stale timeout from an earlier recording must not clear a newer one's pause ---"
run Sources/Core/Engine.swift \
  's/guard token == recordingToken else { return }/guard token != recordingToken else { return }/' \
  HCIFaultsTests/testKeyRecordingPause_StaleTimeoutDoesNotCancelANewerRecording

exit "$fail"
