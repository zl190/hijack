#!/bin/sh
# Mutation checks for MetricsSummary (W3): the hang-max line and the crash-count line.
# Wraps scripts/mutate-check.sh so both checks run as one committed script instead of by hand.
# Usage: scripts/mutate-check-w3-metrics.sh
set -u
cd "$(dirname "$0")/.."
fail=0

run() {
  scripts/mutate-check.sh "$1" "$2" "$3" || fail=1
}

echo "--- hang-max line (longestHangSeconds) ---"
run Sources/Core/MetricsSummary.swift \
  's/longestHangSeconds = max(out.longestHangSeconds ?? 0, seconds)/longestHangSeconds = min(out.longestHangSeconds ?? 999, seconds)/' \
  MetricsSummaryTests/testHangCountAndLongestHangAcrossDiagnosticPayloads

echo "--- crash-count line (crashCount) ---"
run Sources/Core/MetricsSummary.swift \
  's/crashCount += crashes.count/crashCount += 0/' \
  MetricsSummaryTests/testCrashCountAndLastCrashDateAcrossDiagnosticPayloads

exit "$fail"
