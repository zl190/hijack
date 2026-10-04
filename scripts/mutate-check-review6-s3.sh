#!/bin/sh
# Mutation check for review 6, S3: day() must use a fixed UTC time zone, not the host's current one.
# Wraps the existing scripts/mutate-check.sh. Run under TZ=America/Los_Angeles so a west-of-UTC host
# would actually catch a regression here (the mutation still breaks the tests under any zone, since
# dropping the explicit UTC assignment falls back to the test-runner's current default zone).
# Usage: TZ=America/Los_Angeles scripts/mutate-check-review6-s3.sh
set -u
cd "$(dirname "$0")/.."
fail=0

run() {
  scripts/mutate-check.sh "$1" "$2" "$3" || fail=1
}

echo "--- day() must use a fixed UTC zone, not the host's current zone ---"
run Sources/Core/MetricsSummary.swift \
  's/f.timeZone = TimeZone(identifier: "UTC")/f.timeZone = TimeZone.current/' \
  MetricsSummaryTests/testCPUTimeSumsPerDayAcrossMetricPayloads

exit "$fail"
