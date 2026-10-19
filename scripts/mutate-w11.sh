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
  's|return mode.switchesInput ? (.waitingForText, \[.passKey, .watchTool\]) : (.idle, \[.passKey, .finish\])|return (.idle, [.passKey, .finish])|' \
  "$SM/testFollowReleaseWaitsForTheTextThenFinishes"
mutate "a3 following is not active" $M 's~state == .passthrough || state == .following || state == .starting~state == .passthrough || state == .starting~' \
  "$F/testWakeDuringFollowStopsAndRestores"

mutate "a4 the tool's switch-in starts a dictation in every mode" $M 's~case (.idle, .toolStarted) where mode.follow \&\& !mode.toggle \&\& mode.switchesInput:~case (.idle, .toolStarted) where !mode.toggle \&\& mode.switchesInput:~' \
  "$SM/testToolSwitchInStartsADictationOnlyInFollowModeFromIdleOrWaiting"
mutate "a5 a late switch-in while waiting is ignored" $M 's~case (.waitingForText, .toolStarted) where mode.follow \&\& !mode.toggle \&\& mode.switchesInput:~case (.waitingForText, .toolStarted) where false:~' \
  "$SM/testToolSwitchInStartsADictationOnlyInFollowModeFromIdleOrWaiting"

# The engine
mutate "b follow mode is never handed to the machine" $E 's|passthrough: follow ? inVoice \&\& !restorable : sameKey \&\& inVoice, follow: follow)|passthrough: follow ? inVoice \&\& !restorable : sameKey \&\& inVoice, follow: false)|' \
  "$F/testRestoresThePreviousSourceAfterTheToolsWindowCloses"
mutate "b2 a press inside the voice source is passthrough even with a restore pending" $E 's|passthrough: follow ? inVoice \&\& !restorable : sameKey|passthrough: follow ? inVoice : sameKey|' \
  "$F/testChainedPressKeepsThePreviousSourceUntilTheChainEnds"
mutate "b3 the source read at the press is never remembered (the tracked one masks it)" $E 's~if let cur = sourceAtPress, cur != p.voiceID {~if let cur = sourceAtPress, cur == p.voiceID {~' \
  "$F/testTheSourceReadAtThePressWinsOverTheTrackedOne"
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
mutate "b9 a too-short follow press is judged like a dictation" $E 's~if r.follow, r.toolStarted || held >= p.holdDelay {~if r.follow {~' \
  "$F/testPressShorterThanTheHoldDelayIsTooShort"
mutate "b10 a too-short follow press undoes the user's own source switch" $E 's~held < p.holdDelay || record.toolStarted, !record.sawWindow, !record.sawMic~held < 0 || record.toolStarted, !record.sawWindow, !record.sawMic~' \
  "$F/testTooShortPressThatSwitchedTheSourceItselfIsLeftAlone"
mutate "b11 a chained too-short press drops the pending restore" $E 's~record.chained = previous != nil \&\& (sourceAtPress == nil || sourceAtPress == p.voiceID)~record.chained = false~' \
  "$F/testTooShortPressWhileWaitingStillRestores"
mutate "b12 the switch-in notification starts a dictation in hold mode too" $E 's~guard p.follow, !p.toggle, p.switchesInput else { return }~guard !p.toggle, p.switchesInput else { return }~' \
  "$F/testHoldModeIgnoresItsOwnSwitchInAndTracksTheOtherSources"
mutate "b13 a burst of notifications starts a dictation each" $E 's~if machine.state == .waitingForText, record.toolStarted || record.sawSwitchIn { return }~if false { return }~' \
  "$F/testABurstOfNotificationsForOneSwitchInStartsOneDictation"
mutate "b14 the other sources are not tracked" $E 's~lastOtherSource = id; return~return~' \
  "$F/testHoldModeIgnoresItsOwnSwitchInAndTracksTheOtherSources"
mutate "b15 the tracked source is never used as the one to go back to" $E 's~} else if previous == nil, let last = lastOtherSource {~} else if previous == nil, let last = lastOtherSource, false {~' \
  "$F/testToolSwitchInWithNoKeySeenIsADictationEndedByItsMic"
mutate "b16 a switch-in with nothing live still switches back" $E 's~if record.follow, held < p.holdDelay || record.toolStarted, !record.sawWindow, !record.sawMic, !record.chained {~if record.follow, held < p.holdDelay, !record.sawWindow, !record.sawMic, !record.chained {~' \
  "$F/testManualSwitchWithNothingLiveIsLeftAlone"
mutate "b17 the mic does not keep the dictation live" $E 's~let live = byWindow ? window.busy == true : window.busy == true || micTool == true~let live = window.busy == true~' \
  "$F/testToolSwitchInWithNoKeySeenIsADictationEndedByItsMic"
mutate "b18 a window seen does not take over from the mic" $E 's~let live = byWindow ? window.busy == true : window.busy == true || micTool == true~let live = window.busy == true || micTool == true~' \
  "$F/testAWindowSeenEndsTheWatchEvenWhileTheMicIsOn"
mutate "b19 the watch never gives up" $E 's~let gaveUp = liveSince == nil ? waited >= p.fallbackDelay : waited >= cap~let gaveUp = liveSince == nil ? waited >= p.fallbackDelay : false~' \
  "$F/testAStuckLiveReadingOnTheToolPathGivesUpAndLeavesTheSource"
mutate "b20 a start inside the voice source forgets the persisted source" $E 's~lastOtherSource = supervisor.lastOtherSource~lastOtherSource = nil~' \
  "$F/testAStartInsideTheVoiceSourceTakesThePersistedSourceAndTrackingPersistsIt"
mutate "b21 a late switch-in after the key record ended is not chained to it" $E 's~if stayed, !record.toolStarted, held >= p.holdDelay {~if stayed, !record.toolStarted, held >= p.holdDelay, false {~' \
  "$F/testLateSwitchInAfterTheKeyRecordEndedRestoresEvenWithNothingLive"
mutate "b22 the late window never closes" $E 's~if clock.now <= w.until {~if true {~' \
  "$F/testLateSwitchInBeyondRestoreTimeoutIsLeftAlone"
mutate "b23 a switch-in seen while held does not stop a later takeover" $E 's~if machine.state == .waitingForText, record.toolStarted || record.sawSwitchIn { return }~if machine.state == .waitingForText, record.toolStarted { return }~' \
  "$F/testSwitchInWhileTheKeyIsHeldIsAbsorbedAndALaterReselectDoesNotSplit"
mutate "b24 the key path waits the tool-path cap for a window that never closes" $E 's~let cap = record.toolStarted ? Engine.maxToolDictation : p.restoreTimeout~let cap = Engine.maxToolDictation~' \
  "$F/testKeyPathWindowThatNeverClosesRestoresAtRestoreTimeout"
mutate "b25 the tool path restores mid-dictation at the cap" $E 's~if record.toolStarted, record.toolGaveUp {~if record.toolStarted, record.toolGaveUp, false {~' \
  "$F/testAStuckLiveReadingOnTheToolPathGivesUpAndLeavesTheSource"
mutate "b26 a chained press is never recognised" $E 's~record.chained = previous != nil \&\& (sourceAtPress == nil || sourceAtPress == p.voiceID)~record.chained = previous != nil \&\& sourceAtPress == p.voiceID~' \
  "$F/testLateSwitchInAfterTheKeyRecordEndedRestoresEvenWithNothingLive"
mutate "b27 the mic end uses the window grace" $E 's~let grace = byWindow ? capsuleGrace : Engine.micGrace~let grace = capsuleGrace~' \
  "$F/testToolSwitchInWithNoKeySeenIsADictationEndedByItsMic"
mutate "b28 the stale watch completion ends the new dictation" $E '/\[self\] window, micTool, micDevice in/,/let now = clock.now/ s~guard gen == generation, machine.state == .waitingForText else { return }~_ = gen~' \
  "$F/testAStaleWatchCompletionAfterANewPressIsDropped"
mutate "e4 stats scores a follow line without a restore as text arrived" $S 's~outcome = follow \&\& !line.contains("back after") ? .notRestored : .textArrived~outcome = .textArrived~' \
  "$F/testStatsParsesFollowLines"
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
mutate "e2 stats counts a follow line as a too-short tap" $S 's~} else if line.contains("released before") || line.contains("left alone") || (sent == nil \&\& !follow) {~} else if sent == nil {~' \
  "$F/testStatsParsesFollowLines"

# Static checks: the app side carries the mode end to end, and the follow pid lookup runs off the tap callback.
if grep -q 'follow: m.followMode' Sources/App/System.swift && grep -q 'followMode ? key : m.customTrigger ?? key' Sources/App/System.swift \
  && grep -q 'DictationMode.all.contains(value)' Sources/App/CLI.swift && grep -q 'DictationMode.all.contains' Sources/App/Config.swift \
  && grep -q 'value: "follow"' Sources/App/Menu.swift && grep -q 'triggerMode = "follow"' Sources/App/Settings.swift \
  && awk '/case .rememberSource:/ { inb = 1 } inb && /clock.after\(0\)/ { after = 1 } inb && after && /voicePIDs = probes.processIDs/ { found = 1 } inb && /sampleWhileHeld\(gen: gen, after: 0.3\)/ { inb = 0 } END { exit !found }' $E; then
  echo "PASS static grep: follow reaches Plan, CLI, Config, menu and Settings; the pid lookup is off the tap callback"
else
  echo "FAIL static grep: an app-side path lost the mode, or the pid lookup runs inside the tap callback"; fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
