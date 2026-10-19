#!/bin/sh
# Mutation checks for W10 (the key-listener chain on every dictation line, and no relaunch behind another listener), docs/adr/0023.
# For each mutation: break one line of shipped code with sed, the named tests must go RED; restore it,
# the same tests must go GREEN. Prints two lines per mutation (broken, restored), PASS or FAIL.
# Usage: scripts/mutate-w10.sh        Exit 0 only when every mutation passes. Files are restored on every exit.
set -u
cd "$(dirname "$0")/.."
fail=0
current=""
restore() { [ -n "$current" ] && [ -f "$current.w10orig" ] && mv "$current.w10orig" "$current"; current=""; }
trap restore EXIT
trap 'restore; exit 130' INT TERM

green() { swift test --filter "$1" 2>&1 | grep -q "with 0 failures" && ! swift test --filter "$1" 2>&1 | grep -q "error: -\["; }
red() { ! swift test --filter "$1" >/dev/null 2>&1; }

mutate() { # name file sed-expression test-filter
  name="$1"; file="$2"; expr="$3"; filter="$4"
  cp "$file" "$file.w10orig"; current="$file"
  sed -i '' "$expr" "$file"
  if cmp -s "$file" "$file.w10orig"; then
    echo "FAIL $name: the sed expression changed nothing"; fail=1; mv "$file.w10orig" "$file"; current=""; return
  fi
  if red "$filter"; then echo "PASS $name: broken -> tests RED"; else echo "FAIL $name: broken -> tests stayed GREEN"; fail=1; fi
  mv "$file.w10orig" "$file"; current=""
  if green "$filter"; then echo "PASS $name: restored -> tests GREEN"; else echo "FAIL $name: restored -> tests not green"; fail=1; fi
}

E=Sources/Core/Engine.swift
T=ListenerChainTests
mutate "a summary always prints ahead: none" $E 's|return a.isEmpty ? "none" : a.joined(separator: "+")|return "none"|' \
  "$T/testSummaryNamesTheListenersAheadInChainOrder"
mutate "a2 unreadable chain prints ahead: none" $E 's|guard let a else { return "?" }|guard let a else { return "none" }|' \
  "$T/testSummarySaysAheadUnknownWhenTheChainCouldNotBeRead"
mutate "b chain read on every sample" $E 's|if !record.sampled, plan.style == "hold" {|if plan.style == "hold" {|' \
  "$T/testChainIsReadOncePerDictation"
mutate "c relaunch guard inverted (skips when ours is first)" $E 's|if let ahead = r.ahead, !ahead.isEmpty {|if let ahead = r.ahead, ahead.isEmpty {|' \
  "$T/(testFailedPostBehindAnotherListenerDoesNotRelaunchAndSaysWhy|testFailedPostWithOurListenerFirstRelaunches)"
mutate "c2 relaunch guard dropped" $E 's|if let ahead = r.ahead, !ahead.isEmpty {|if let ahead = r.ahead, false {|' \
  "$T/testFailedPostBehindAnotherListenerDoesNotRelaunchAndSaysWhy"
mutate "c3 unread chain counts as a listener ahead" $E 's|if let ahead = r.ahead, !ahead.isEmpty {|if r.ahead?.isEmpty != true, let ahead = r.ahead ?? Optional(["?"]) {|' \
  "$T/testFailedPostWithUnknownChainRelaunches"
mutate "d stats ignores the ahead field" Sources/Core/Stats.swift 's|word(#"ahead: (\[^,\|\]+)"#)|word(#"ahead-: ([^,\|]+)"#)|' \
  "$T/testStatsCountsListenersAhead"
mutate "d2 stats counts a failure as any listener ahead" Sources/Core/Stats.swift 's|$0.listenersAhead?.isEmpty == false \&\& $0.echoSeen == false|$0.listenersAhead?.isEmpty == false|' \
  "$T/testStatsCountsListenersAhead"

# Static checks: the live chain read keeps to enabled, filtering, key-event taps at the HID level, and the
# doctor command uses the same function (one definition of "ahead").
L=Sources/App/System.swift
if grep -q '\.tapPoint == \.cghidEventTap' $L && grep -q '\$0\.enabled' $L && grep -q 't\.options == \.defaultTap' $L \
  && [ "$(grep -c 'func keyListenersAhead(of pid: pid_t)' $L)" = 1 ] && grep -q 'keyListenersAhead(of: st.pid)' Sources/App/CLI.swift; then
  echo "PASS static grep: keyListenersAhead filters hid/enabled/filtering key taps, defined once, used by doctor"
else
  echo "FAIL static grep: keyListenersAhead filter or doctor use is missing"; fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
