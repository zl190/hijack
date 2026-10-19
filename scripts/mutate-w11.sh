#!/bin/sh
# Mutation checks for W11 (follow mode: the tool starts itself on its own talk key, Hijack only switches back), docs/adr/0024.
# For each mutation: break one line of shipped code with sed, the named tests must go RED; restore it,
# the same tests must go GREEN. A mutant that does not compile is a FAIL (a build error is not a RED test).
# Usage: scripts/mutate-w11.sh        Exit 0 only when every mutation passes. Files are restored on every exit.
set -u
cd "$(dirname "$0")/.."
fail=0
current=""
restore() { [ -n "$current" ] && [ -f "$current.w11orig" ] && mv "$current.w11orig" "$current"; current=""; }
trap restore EXIT
trap 'restore; exit 130' INT TERM

green() { swift test --filter "$1" 2>&1 | grep -q "with 0 failures" && ! swift test --filter "$1" 2>&1 | grep -q "error: -\["; }
red() { ! swift test --filter "$1" >/dev/null 2>&1; }

mutate() { # name file sed-expression test-filter
  name="$1"; file="$2"; expr="$3"; filter="$4"
  cp "$file" "$file.w11orig"; current="$file"
  sed -i '' "$expr" "$file"
  if cmp -s "$file" "$file.w11orig"; then
    echo "FAIL $name: the sed expression changed nothing"; fail=1; mv "$file.w11orig" "$file"; current=""; return
  fi
  if ! swift build --build-tests >/dev/null 2>&1; then
    echo "FAIL $name: the mutant does not compile (a build error is not a RED test)"; fail=1
    mv "$file.w11orig" "$file"; current=""; return
  fi
  if red "$filter"; then echo "PASS $name: broken -> tests RED"; else echo "FAIL $name: broken -> tests stayed GREEN"; fail=1; fi
  mv "$file.w11orig" "$file"; current=""
  if green "$filter"; then echo "PASS $name: restored -> tests GREEN"; else echo "FAIL $name: restored -> tests not green"; fail=1; fi
}

M=Sources/Core/SessionMachine.swift
E=Sources/Core/Engine.swift
S=Sources/Core/Stats.swift
F=FollowModeTests
SM=SessionMachineTests

# The machine
mutate "a follow press starts a posted dictation" $M 's|if mode.follow \&\& !mode.toggle { return (.following|if mode.follow \&\& mode.toggle { return (.following|' \
  "$SM/testFollowPressPassesTheKeyAndRemembersTheSource"
mutate "a2 following release finishes without the window watch" $M \
  's|return mode.switchesInput ? (.waitingForText, \[.passKey, .waitForText\]) : (.idle, \[.passKey, .finish\])|return (.idle, [.passKey, .finish])|' \
  "$SM/testFollowReleaseWaitsForTheTextThenFinishes"
mutate "a3 following is not active" $M 's~state == .passthrough || state == .following || state == .starting~state == .passthrough || state == .starting~' \
  "$F/testWakeDuringFollowStopsAndRestores"

# The engine
mutate "b follow mode is never handed to the machine" $E 's|passthrough: follow ? inVoice \&\& previous == nil : sameKey \&\& inVoice, follow: follow)|passthrough: follow ? inVoice \&\& previous == nil : sameKey \&\& inVoice, follow: false)|' \
  "$F/testRestoresThePreviousSourceAfterTheToolsWindowCloses"
mutate "b2 a press inside the voice source is passthrough even with a restore pending" $E 's|passthrough: follow ? inVoice \&\& previous == nil : sameKey|passthrough: follow ? inVoice : sameKey|' \
  "$F/testChainedPressKeepsThePreviousSourceUntilTheChainEnds"
mutate "b3 the previous source is never remembered" $E 's|if let cur = sourceAtPress, cur != p.voiceID { previous = cur }|if let cur = sourceAtPress, cur == p.voiceID { previous = cur }|' \
  "$F/testRestoresThePreviousSourceAfterTheToolsWindowCloses"
mutate "b4 repeats while following are swallowed" $E 's|if down == physicalDown { return machine.passesKeyThrough }|if down == physicalDown { return machine.state == .passthrough }|' \
  "$F/testRepeatsWhileFollowingPass"
mutate "b5 toggle no longer wins over follow" $E 's~let follow = p.follow \&\& !p.toggle~let follow = p.follow~' \
  "$F/testToggleWinsOverFollow"
mutate "b6 the release time is not recorded for a follow dictation" $E 's~before == .starting || before == .listening || before == .following~before == .starting || before == .listening~' \
  "$F/testRestoresThePreviousSourceAfterTheToolsWindowCloses"
mutate "b7 a stale remembered source survives a passthrough release" $E 's~if machine.state == .idle, before != .idle, !effects.contains(.finish), previous != nil {~if machine.state == .idle, before != .idle, !effects.contains(.finish), previous != nil, false {~' \
  "$F/testStalePreviousFromAPassthroughReleaseIsDropped"
mutate "b8 the source is read at every press" $E 's~if (sameKey || follow) \&\& p.switchesInput { sourceAtPress = sources.current() }~if p.switchesInput { sourceAtPress = sources.current() }~' \
  "$F/testPressesReadTheInputSourceOnlyWhenTheAnswerIsNeeded"
mutate "b9 a too-short follow press is judged like a dictation" $E 's~if r.follow, held < p.holdDelay {~if r.follow, held < 0 {~' \
  "$F/testPressShorterThanTheHoldDelayIsTooShort"
mutate "b10 a too-short follow press undoes the user's own source switch" $E 's~if record.follow, held < p.holdDelay, !record.sawWindow, !record.chained {~if record.follow, held < 0, !record.sawWindow, !record.chained {~' \
  "$F/testTooShortPressThatSwitchedTheSourceItselfIsLeftAlone"
mutate "b11 a chained too-short press drops the pending restore" $E 's~record.chained = previous != nil \&\& sourceAtPress == p.voiceID~record.chained = false~' \
  "$F/testTooShortPressWhileWaitingStillRestores"
mutate "c no mic or window sample while following" $E 's~guard machine.state == .listening || machine.state == .following, gen == generation else { return }~guard machine.state == .listening, gen == generation else { return }~' \
  "$F/testSamplesWhileHeldReadMicAndWindowOnly"
mutate "c2 the key-listener chain is read for a key that was never posted" $E 's|let readChain = !record.sampled \&\& plan.style == "hold" \&\& machine.state == .listening|let readChain = !record.sampled \&\& plan.style == "hold"|' \
  "$F/testSamplesWhileHeldReadMicAndWindowOnly"
mutate "d the summary line calls a follow dictation hold" $E 's|(\\(r.follow ? "follow" : p.toggle ? "toggle" : "hold"))|(\\(p.toggle ? "toggle" : "hold"))|' \
  "$F/testRestoresThePreviousSourceAfterTheToolsWindowCloses"
mutate "d2 a source that stayed is reported as changed by hand" $E 's|let stayed = record.follow \&\& sources.current() == prev|let stayed = false|' \
  "$F/testSourceThatNeverBecameTheVoiceSourceIsLeftAlone"

# Stats
mutate "e stats does not read a follow line" $S 's~(?:hold|toggle|follow)\\):~(?:hold|toggle)\\):~' \
  "$F/testStatsParsesFollowLines"
mutate "e3 stats reads the mode word anywhere on the line" $S 's~let follow = modeWord == "follow"~let follow = line.contains("(follow)")~' \
  "$F/testStatsParsesFollowLines"
mutate "e2 stats counts a follow line as a too-short tap" $S 's~} else if line.contains("released before") || (sent == nil \&\& !follow) {~} else if sent == nil {~' \
  "$F/testStatsParsesFollowLines"

# Static checks: the app side carries the mode end to end, and the follow pid lookup runs off the tap callback.
if grep -q 'follow: m.followMode' Sources/App/System.swift && grep -q 'followMode ? key : m.customTrigger ?? key' Sources/App/System.swift \
  && grep -q '\["hold", "toggle", "follow"\].contains(value)' Sources/App/CLI.swift && grep -q '\["toggle", "follow"\].contains' Sources/App/Config.swift \
  && grep -q 'value: "follow"' Sources/App/Menu.swift && grep -q 'triggerMode = "follow"' Sources/App/Settings.swift \
  && awk '/case .rememberSource:/ { inb = 1 } inb && /clock.after\(0\)/ { after = 1 } inb && after && /voicePIDs = probes.processIDs/ { found = 1 } inb && /sampleWhileHeld\(gen: gen, after: 0.3\)/ { inb = 0 } END { exit !found }' $E; then
  echo "PASS static grep: follow reaches Plan, CLI, Config, menu and Settings; the pid lookup is off the tap callback"
else
  echo "FAIL static grep: an app-side path lost the mode, or the pid lookup runs inside the tap callback"; fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
