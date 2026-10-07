#!/bin/sh
# Mutation checks for W8 (self-relaunch on a failed post), docs/adr/0022-relaunch-on-a-failed-post.md.
# For each mutation: break one line of shipped code with sed, the named tests must go RED; restore it,
# the same tests must go GREEN. Prints two lines per mutation (broken, restored), PASS or FAIL.
# Usage: scripts/mutate-w8.sh        Exit 0 only when every mutation passes. Files are restored on every exit.
set -u
cd "$(dirname "$0")/.."
fail=0
current=""
restore() { [ -n "$current" ] && [ -f "$current.w8orig" ] && mv "$current.w8orig" "$current"; current=""; }
trap restore EXIT
trap 'restore; exit 130' INT TERM

green() { swift test --filter "$1" 2>&1 | grep -q "with 0 failures" && ! swift test --filter "$1" 2>&1 | grep -q "error: -\["; }
red() { ! swift test --filter "$1" >/dev/null 2>&1; }

mutate() { # name file sed-expression test-filter
  name="$1"; file="$2"; expr="$3"; filter="$4"
  cp "$file" "$file.w8orig"; current="$file"
  sed -i '' "$expr" "$file"
  if cmp -s "$file" "$file.w8orig"; then
    echo "FAIL $name: the sed expression changed nothing"; fail=1; mv "$file.w8orig" "$file"; current=""; return
  fi
  if red "$filter"; then echo "PASS $name: broken -> tests RED"; else echo "FAIL $name: broken -> tests stayed GREEN"; fail=1; fi
  mv "$file.w8orig" "$file"; current=""
  if green "$filter"; then echo "PASS $name: restored -> tests GREEN"; else echo "FAIL $name: restored -> tests not green"; fail=1; fi
}

E=Sources/Core/Engine.swift
T=SelfRelaunchTests
mutate "a relaunch call dropped" $E 's|if supervisor.relaunch(reason: why) {|if why.isEmpty {|' \
  "$T/(testFailedPostRelaunchesOnceAfterTheSummaryLine|testSecondFailureElevenMinutesLaterRelaunches)"
mutate "b hold threshold 0.5 s -> 0.0 s" $E 's|relaunchMinHold: TimeInterval = 0.5|relaunchMinHold: TimeInterval = 0.0|' \
  "$T/testHeldUnderHalfASecondDoesNotRelaunch"
mutate "b2 hold threshold 0.5 s -> 0.6 s" $E 's|relaunchMinHold: TimeInterval = 0.5|relaunchMinHold: TimeInterval = 0.6|' \
  "$T/testHeldJustOverHalfASecondRelaunches"
mutate "c postSeen == false instead of != true" $E 's|r.postSeen != true|r.postSeen == false|' \
  "$T/testUnsampledProbeCountsAsNotSeen"
mutate "c2 postSeen condition dropped" $E 's|, r.postSeen != true||' \
  "$T/testPostSeenDoesNotRelaunch"
mutate "d rate limit 10 min -> 0" $E 's|relaunchGap: TimeInterval = 600|relaunchGap: TimeInterval = 0|' \
  "$T/(testSecondFailureNineMinutesLaterIsSuppressed|testPersistedDateSuppressesInAFreshProcess)"
mutate "d2 rate limit 10 min -> 20 min" $E 's|relaunchGap: TimeInterval = 600|relaunchGap: TimeInterval = 1200|' \
  "$T/(testSecondFailureElevenMinutesLaterRelaunches|testPersistedDateOlderThanTheGapRelaunches)"
mutate "d3 relaunch time not persisted" $E 's|supervisor.lastRelaunchAt = clock.now|_ = clock.now|' \
  "$T/(testFailedPostRelaunchesOnceAfterTheSummaryLine|testSecondFailureNineMinutesLaterIsSuppressed)"
mutate "g echo condition dropped" $E 's|, r.echoMs == nil, r.postSeen|, r.postSeen|' \
  "$T/(testEchoSeenDoesNotRelaunch|testEchoSeenWithMicOffDoesNotRelaunch)"
mutate "h key-sent condition dropped" $E 's|r.keySentMs != nil, r.echoMs|r.echoMs|' \
  "$T/testKeyNeverSentDoesNotRelaunch"
mutate "i hold-style condition dropped" $E 's|guard p.style == "hold", held|guard held|' \
  "$T/testTapStyleDoesNotRelaunch"
mutate "j active-session guard dropped" $E 's|guard !machine.isActive else|guard true else|' \
  "$T/testNoRelaunchWhileANewerSessionIsActive"
mutate "k started line never says after self-relaunch" $E 's|(supervisor.takeSelfRelaunchMark() ? " (after self-relaunch)" : "")|(supervisor.takeSelfRelaunchMark() ? "" : "")|' \
  "$T/testStartedLineSaysAfterSelfRelaunchOnce"
mutate "l relaunch inside the callback, not on the next turn" $E 's|clock.after(0, relaunchNextTurn)|relaunchNextTurn()|' \
  "$T/testAppProviderRelaunchHappensAfterTheCallbackReturns"
mutate "m rate limit used up even when the spawn failed" $E 's|if supervisor.relaunch(reason: why) { supervisor.lastRelaunchAt = clock.now }|_ = supervisor.relaunch(reason: why); supervisor.lastRelaunchAt = clock.now|' \
  "$T/testFailedSpawnDoesNotConsumeTheRateLimit"
mutate "n session guard inside the scheduled block dropped" $E 's|guard !machine.isActive else { trace("self-relaunch cancelled: a session started"); return }|_ = 0|' \
  "$T/testNewSessionBeforeTheScheduledRelaunchCancelsIt"
mutate "e stats counts suppressed lines too" Sources/Core/Stats.swift 's|contains("self-relaunch: ")|contains("self-relaunch")|' \
  "$T/testStatsCountsRelaunchesNotSuppressed"

# Static check (f): the menu and the supervisor share one relaunch function, and there is one `open -b` spawn.
n_open=$(grep -rn 'open -b com.zl190.hijack' Sources | wc -l | tr -d ' ')
if grep -q 'relaunchProcess(selfInitiated: false)' Sources/App/Menu.swift \
  && grep -q 'relaunchProcess(selfInitiated: true)' Sources/App/System.swift \
  && ! grep -q 'Process()' Sources/App/Menu.swift && [ "$n_open" = "1" ]; then
  echo "PASS static grep: Menu.swift and LiveSupervisor share relaunchProcess, one open -b spawn in Sources"
else
  echo "FAIL static grep: the relaunch path is duplicated (open -b spawns: $n_open)"; fail=1
fi

# Static checks on the App side (no test can run the real Process): the relauncher waits for our pid with a cap,
# the log is flushed before the quit, the lock is retried after a self-relaunch.
L=Sources/App/System.swift
if grep -q 'kill -0 \\(getpid())' $L && grep -q '\[ \$n -lt 100 \]' $L && grep -q 'open -b com.zl190.hijack' $L && ! grep -q 'sleep 0.5; open' $L; then
  echo "PASS static grep: the relauncher shell waits for our pid (cap 10 s), no fixed sleep"
else
  echo "FAIL static grep: the pid wait loop is gone from the relauncher shell string"; fail=1
fi
if grep -A1 'flushLog()' $L | grep -q 'NSApp.terminate' && grep -A1 'engine.stopForQuit()' Sources/App/Menu.swift | grep -q 'flushLog()'; then
  echo "PASS static grep: the log is flushed before terminate (relaunchProcess) and in applicationWillTerminate"
else
  echo "FAIL static grep: a flushLog() call before terminate is missing"; fail=1
fi
if grep -q 'usleep(100_000)' Sources/App/main.swift && grep -q 'instance lock acquired after' Sources/App/main.swift; then
  echo "PASS static grep: main.swift retries the instance lock after a self-relaunch"
else
  echo "FAIL static grep: the lock retry is gone from main.swift"; fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
