#!/bin/sh
# Mutation checks for W9 (App Nap state on every dictation line), docs/incidents/2026-10-04-echo-missing.md.
# For each mutation: break one line of shipped code with sed, the named tests must go RED; restore it,
# the same tests must go GREEN. Prints two lines per mutation (broken, restored), PASS or FAIL.
# Usage: scripts/mutate-w9.sh        Exit 0 only when every mutation passes. Files are restored on every exit.
set -u
cd "$(dirname "$0")/.."
fail=0
current=""
restore() { [ -n "$current" ] && [ -f "$current.w9orig" ] && mv "$current.w9orig" "$current"; current=""; }
trap restore EXIT
trap 'restore; exit 130' INT TERM

green() { swift test --filter "$1" 2>&1 | grep -q "with 0 failures" && ! swift test --filter "$1" 2>&1 | grep -q "error: -\["; }
red() { ! swift test --filter "$1" >/dev/null 2>&1; }

mutate() { # name file sed-expression test-filter
  name="$1"; file="$2"; expr="$3"; filter="$4"
  cp "$file" "$file.w9orig"; current="$file"
  sed -i '' "$expr" "$file"
  if cmp -s "$file" "$file.w9orig"; then
    echo "FAIL $name: the sed expression changed nothing"; fail=1; mv "$file.w9orig" "$file"; current=""; return
  fi
  if red "$filter"; then echo "PASS $name: broken -> tests RED"; else echo "FAIL $name: broken -> tests stayed GREEN"; fail=1; fi
  mv "$file.w9orig" "$file"; current=""
  if green "$filter"; then echo "PASS $name: restored -> tests GREEN"; else echo "FAIL $name: restored -> tests not green"; fail=1; fi
}

E=Sources/Core/Engine.swift
T=AppNapTests
mutate "a summary always prints nap: off" $E 's|return ", nap: \\(s.napped ? "on" : "off"), role: \\(s.role)"|return ", nap: off, role: \\(s.role)"|' \
  "$T/(testNappedShowsNapOnAndTheRole|testStartedAndRelaunchLinesCarryNapFromAReadAtThatMoment|testNapIsIndependentOfPostSeen)"
mutate "a2 unreadable prints nap: off" $E 's|guard let s else { return ", nap: ?" }|guard let s else { return ", nap: off" }|' \
  "$T/(testUnreadableShowsNapQuestionMarkAndNoRole|testTapStyleHasNoSample|testReleaseBeforeTheSampleHasNoSample)"
mutate "b stats counts nap: ? as napped" Sources/Core/Stats.swift 's|napped: dictLines.filter { $0.contains("nap: on") }.count|napped: dictLines.filter { $0.contains("nap: on") \|\| $0.contains("nap: ?") }.count|' \
  "$T/testStatsCountsNappedSampledAndFailed"
mutate "b2 stats counts nap: ? as sampled" Sources/Core/Stats.swift 's|$0.contains("nap: on") \|\| $0.contains("nap: off") }.count|$0.contains("nap: ") }.count|' \
  "$T/testStatsCountsNappedSampledAndFailed"
mutate "c sample taken from postSeen instead of the probe" $E 's|record.heldProcess = probes.processState()|record.heldProcess = record.postSeen.map { ProcessState(napped: !$0, role: 0) }|' \
  "$T/(testNapIsIndependentOfPostSeen|testNappedShowsNapOnAndTheRole)"
mutate "d started line drops the nap suffix" $E 's|(after self-relaunch)" : "") + napNow())|(after self-relaunch)" : ""))|' \
  "$T/testStartedAndRelaunchLinesCarryNapFromAReadAtThatMoment"
mutate "d2 relaunch line drops the nap suffix" $E 's|log("self-relaunch: \\(why)\\(napNow())")|log("self-relaunch: \\(why)")|' \
  "$T/testStartedAndRelaunchLinesCarryNapFromAReadAtThatMoment"
mutate "e sample moved to every state (no hold-style gate)" $E 's|if record.postSeen == nil, plan.style == "hold" {|if record.postSeen == nil {|' \
  "$T/testTapStyleHasNoSample"

# Static check: LiveProbes reads flavor 3 (TASK_SUPPRESSION_POLICY) with 16 words, and never flavor 4 (TASK_POLICY_STATE, root-only).
L=Sources/App/System.swift
if grep -q 'task_policy_flavor_t(3)' $L && grep -q 'count: 16)' $L && grep -q 'mach_msg_type_number_t(16)' $L \
  && ! grep -q 'task_policy_flavor_t(4)' $L; then
  echo "PASS static grep: LiveProbes uses flavor 3 with count 16 and never flavor 4"
else
  echo "FAIL static grep: LiveProbes flavor/count is not 3 / 16, or flavor 4 is used"; fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
