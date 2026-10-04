#!/bin/sh
# Mutation check for one test: break a source line, the test must go red; restore it, the test must go green.
# Usage: scripts/mutate-check.sh <file> <sed-expression> <test-filter>
# Example: scripts/mutate-check.sh Sources/Core/UpdateNotice.swift 's/orderedDescending else/orderedAscending else/' UpdateNoticeTests
# Exit 0 only when both steps hold. The file is restored on every exit.
set -u
cd "$(dirname "$0")/.."
file="$1"; expr="$2"; filter="$3"
cp "$file" "$file.orig"
trap 'mv "$file.orig" "$file"' EXIT
sed -i '' "$expr" "$file"
cmp -s "$file" "$file.orig" && { echo "mutation did not change $file"; exit 2; }
echo "== broken: $expr"
if swift test --filter "$filter" >/dev/null 2>&1; then echo "   test stayed GREEN: the assertion does not cover this line"; exit 1; fi
echo "   test went RED"
mv "$file.orig" "$file"; cp "$file" "$file.orig"
echo "== restored"
if swift test --filter "$filter" 2>&1 | grep -q "with 0 failures"; then echo "   test is GREEN"; else echo "   test stayed RED"; exit 1; fi
