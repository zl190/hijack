#!/bin/sh
# Mutation checks for review 6, S1: the unknown-unit guess, the hangDuration fallback chain, and the
# cpuTimeUnparsed flag. Wraps scripts/mutate-check.sh so all three run as one committed script.
# Usage: scripts/mutate-check-review6-s1.sh
set -u
cd "$(dirname "$0")/.."
fail=0

run() {
  scripts/mutate-check.sh "$1" "$2" "$3" || fail=1
}

echo "--- unknown unit must be nil, not guessed as 1x the base unit ---"
run Sources/Core/MetricsSummary.swift \
  's/guard let factor = units\[unit\] else { return nil }/let factor = units[unit] ?? 1/' \
  MetricsSummaryTests/testMeasurementIsNilForAnUnknownUnit

echo "--- hangDuration must fall back to diagnosticMetaData ---"
run Sources/Core/MetricsSummary.swift \
  's/(h\["diagnosticMetaData"\] as? \[String: Any\])?\["hangDuration"\]/nil/' \
  MetricsSummaryTests/testHangDurationFallsBackToDiagnosticMetaData

echo "--- hangDuration must fall back to metaData ---"
run Sources/Core/MetricsSummary.swift \
  's/(h\["metaData"\] as? \[String: Any\])?\["hangDuration"\]/nil/' \
  MetricsSummaryTests/testHangDurationFallsBackToMetaData

echo "--- an unparsed cumulativeCPUTime must be flagged, not silently dropped ---"
run Sources/Core/MetricsSummary.swift \
  's/out.cpuTimeUnparsed = true; out.parseWarnings += 1/out.parseWarnings += 0/' \
  MetricsSummaryTests/testAnUnparseableCPUTimeOrPeakMemoryIsFlaggedNotZero

exit "$fail"
