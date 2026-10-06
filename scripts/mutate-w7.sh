#!/bin/sh
# Mutation checks for W7 (event source rebuild + post-seen probe), docs/incidents/2026-10-04-echo-missing.md.
# For each mutation: break one line of shipped code with sed, the named tests must go RED; restore it,
# the same tests must go GREEN. Prints two lines per mutation (broken, restored), PASS or FAIL.
# Usage: scripts/mutate-w7.sh        Exit 0 only when every mutation passes. Files are restored on every exit.
set -u
cd "$(dirname "$0")/.."
fail=0
current=""
trap '[ -n "$current" ] && [ -f "$current.w7orig" ] && mv "$current.w7orig" "$current"' EXIT INT TERM

green() { swift test --filter "$1" 2>&1 | grep -q "with 0 failures" && ! swift test --filter "$1" 2>&1 | grep -q "error: -\["; }
red() { ! swift test --filter "$1" >/dev/null 2>&1; }

mutate() { # name file sed-expression test-filter
  name="$1"; file="$2"; expr="$3"; filter="$4"
  cp "$file" "$file.w7orig"; current="$file"
  sed -i '' "$expr" "$file"
  if cmp -s "$file" "$file.w7orig"; then
    echo "FAIL $name: the sed expression changed nothing"; fail=1; mv "$file.w7orig" "$file"; current=""; return
  fi
  if red "$filter"; then echo "PASS $name: broken -> tests RED"; else echo "FAIL $name: broken -> tests stayed GREEN"; fail=1; fi
  mv "$file.w7orig" "$file"; current=""
  if green "$filter"; then echo "PASS $name: restored -> tests GREEN"; else echo "FAIL $name: restored -> tests not green"; fail=1; fi
}

E=Sources/Core/Engine.swift
mutate "a rebuild-on-wake dropped" $E 's|if wake == .systemWake { keys.rebuild(reason: "system wake") }||' \
  'EventSourceTests/testSystemWakeRebuildsTheSource'
mutate "a2 rebuild also on screen unlock" $E 's|if wake == .systemWake { keys.rebuild|if true { keys.rebuild|' \
  'EventSourceTests/testScreenUnlockDoesNotRebuildTheSource'
mutate "b idle threshold 10 min -> 100 min" $E 's|idleRebuildAfter: TimeInterval = 600|idleRebuildAfter: TimeInterval = 6000|' \
  'EventSourceTests/(testPressAfterElevenMinutesRebuildsBeforeThePost|testTenMinutesAndASecondRebuilds)'
mutate "b2 idle boundary > -> >=" $E 's|> Self.idleRebuildAfter|>= Self.idleRebuildAfter|' \
  'EventSourceTests/testExactlyTenMinutesDoesNotRebuild'
mutate "c summary always prints post: seen" $E 's|r.postSeen.map { $0 ? "seen" : "not seen" } ?? "?"|"seen"|' \
  'EventSourceTests/testSummaryHasPostNotSeenWhenTheKeyStateIsUp'
mutate "d stats ignores post: not seen" Sources/Core/Stats.swift 's|line.contains("post: not seen")|line.contains("post: NOT-SEEN")|' \
  'StatsTests/(testPostFieldDoesNotBreakParsingAndIsRead|testPostNotSeenWithoutAnEchoFieldIsKeyNotSent)'

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
