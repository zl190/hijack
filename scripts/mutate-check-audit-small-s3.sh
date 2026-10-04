#!/bin/sh
# Mutation check for the audit-small review (docs/review-6/audit-small-review.md), S3: resumeFromKeyRecording
# must actually clear `paused`, not just invalidate the token. "paused = false" also appears in
# pauseForKeyRecording's timeout closure, so this mutation addresses the one line inside
# resumeFromKeyRecording by line number rather than by (ambiguous, duplicated) text.
# Usage: scripts/mutate-check-audit-small-s3.sh
set -u
cd "$(dirname "$0")/.."
fail=0

run() {
  scripts/mutate-check.sh "$1" "$2" "$3" || fail=1
}

echo "--- resumeFromKeyRecording must set paused = false, not true ---"
run Sources/Core/Engine.swift \
  '459s/paused = false/paused = true/' \
  HCIFaultsTests/testResumeFromKeyRecording_PressRunsAfterANormalFinish

exit "$fail"
