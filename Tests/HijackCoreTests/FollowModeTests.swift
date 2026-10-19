import XCTest

@testable import HijackCore

// W11 (docs/adr/0024-follow-mode.md): the voice tool starts itself on its own physical talk key; Hijack never posts a
// key and only switches the input source back after the text landed. Evidence for why: docs/incidents/2026-10-04-echo-missing.md,
// section 2026-10-19 (WeType 3.0 swallows a posted Fn and acts on a physical one).
final class FollowModeTests: XCTestCase {
    /// A follow-mode rig: Fn is the trigger and the talk key, the user types in English. The tool is not listening
    /// (`micTool` off) unless a test says so: in follow mode its mic is one of the two signals that keep a dictation live.
    private func rig(current: String? = Rig.english) -> Rig {
        let r = Rig(follow: true, current: current)
        r.probes.micTool = false
        return r
    }

    // The whole dictation: press (WeType switches itself in), speak, release, its window goes, Hijack switches back.
    func testRestoresThePreviousSourceAfterTheToolsWindowCloses() {
        let r = rig(); r.probes.micTool = true
        XCTAssertTrue(r.press(), "the physical talk key passes to the tool")
        XCTAssertEqual(r.engine.machine.state, .following)
        XCTAssertEqual(r.engine.previous, Rig.english)
        XCTAssertEqual(r.sources.selected, [], "no switch: the tool switches itself in")
        r.sources.currentID = Rig.voice  // WeType took the physical Fn and switched itself in
        r.probes.window = .visible(1)
        r.clock.advance(1.0)
        XCTAssertTrue(r.release(), "the release passes too")
        XCTAssertEqual(r.engine.machine.state, .waitingForText)
        r.clock.advance(0.5)
        r.probes.window = .none("no window (pid 100)")  // the text landed
        r.clock.advance(0.5)
        XCTAssertEqual(r.engine.machine.state, .idle)
        XCTAssertEqual(r.sources.selected, [Rig.english], "switched back once, to where the user was")
        XCTAssertEqual(r.sources.currentID, Rig.english)
        XCTAssertNil(r.engine.previous, "consumed by the restore")
        XCTAssertTrue(r.keys.posted.isEmpty, "nothing was ever posted")
        XCTAssertEqual(r.keys.rebuilds, [], "no post, so no event source to rebuild")
        let l = r.sink.summaries.last ?? ""
        XCTAssertTrue(l.hasPrefix("dictation \(Rig.voice) (follow): held 1.00s, window closed "), l)
        XCTAssertTrue(l.contains(", back after 0."), l)
        XCTAssertTrue(l.contains(" | mic tool on device on, window while held: 1 window | front=test"), l)
        for absent in ["sent after", "echo", "ahead:", "nap:", "released before"] { XCTAssertFalse(l.contains(absent), "\(absent): \(l)") }
        XCTAssertEqual(r.supervisor.relaunches, [], "nothing was posted, so nothing to relaunch over")
        XCTAssertEqual(r.sink.reports.map(\.phase), ["listening", "finishing", "done"])
    }

    // Already in WeType at the press: exactly today's passthrough. No record, no line, nothing to restore.
    func testAlreadyInTheVoiceSourceIsPassthroughAndRestoresNothing() {
        let r = rig(current: Rig.voice)
        XCTAssertNil(r.engine.lastOtherSource, "setup: no other source was ever seen, so nowhere to go back to")
        XCTAssertTrue(r.press())
        XCTAssertEqual(r.engine.machine.state, .passthrough)
        XCTAssertNil(r.engine.previous)
        r.clock.advance(1.0)
        XCTAssertTrue(r.release())
        XCTAssertEqual(r.engine.machine.state, .idle)
        r.clock.advance(6.0)
        XCTAssertEqual(r.sources.selected, [], "nothing switched")
        XCTAssertEqual(r.sources.currentID, Rig.voice, "the user stays in the voice source")
        XCTAssertEqual(r.sink.summaries, [], "no dictation of ours to write up")
        XCTAssertTrue(r.keys.posted.isEmpty)
    }

    // WeType did not take the key (its global shortcut off, say): the source never changed, so nothing is switched.
    func testSourceThatNeverBecameTheVoiceSourceIsLeftAlone() {
        let r = rig()
        r.press(); r.clock.advance(1.0); r.release()
        r.clock.advance(2.6)  // fallbackDelay: no window was ever seen
        XCTAssertEqual(r.engine.machine.state, .idle)
        XCTAssertEqual(r.sources.selected, [], "the user is still where they were: no switch")
        XCTAssertNil(r.engine.previous)
        let l = r.sink.summaries.last ?? ""
        XCTAssertTrue(
            l.contains("(follow): held 1.00s, window never closed after release, input source stayed, nothing to switch back | mic tool"), l
        )
        XCTAssertEqual(r.lastEntry()?.outcome, .noWindow)
        XCTAssertNotEqual(r.lastEntry()?.cause, .keyNotSent)
        XCTAssertNotEqual(r.lastEntry()?.cause, .takenAhead)
    }

    // The user switched elsewhere by hand before the text landed: not switched back (the hold-mode rule, kept).
    func testSourceChangedByHandIsNotSwitchedBack() {
        let r = rig()
        r.press(); r.sources.currentID = Rig.voice; r.clock.advance(1.0); r.release()
        r.sources.currentID = "com.apple.keylayout.US"
        r.clock.advance(2.6)
        XCTAssertEqual(r.sources.selected, [])
        XCTAssertTrue(
            (r.sink.summaries.last ?? "").contains("input source already changed, not switched back"), r.sink.summaries.last ?? "")
    }

    // A press while the restore is pending chains the dictation: the previous source is kept until the chain ends (FM-17).
    func testChainedPressKeepsThePreviousSourceUntilTheChainEnds() {
        let r = rig()
        r.press(); r.sources.currentID = Rig.voice; r.probes.window = .visible(1); r.clock.advance(1.0); r.release()
        r.clock.advance(0.3)
        XCTAssertEqual(r.engine.machine.state, .waitingForText, "setup")
        XCTAssertTrue(r.press(), "the next press, still in the voice source")
        XCTAssertEqual(r.engine.machine.state, .following, "a chained dictation, not passthrough")
        XCTAssertEqual(r.engine.previous, Rig.english, "kept")
        XCTAssertTrue(
            (r.sink.summaries.last ?? "").contains(
                "(follow): held 1.00s, window never closed after release, interrupted by the next press"), r.sink.summaries.last ?? "")
        r.clock.advance(1.0); r.release(); r.clock.advance(0.2)
        r.probes.window = .none("no window (pid 100)")
        r.clock.advance(0.5)
        XCTAssertEqual(r.engine.machine.state, .idle)
        XCTAssertEqual(r.sources.selected, [Rig.english], "one restore, at the end of the chain")
        XCTAssertEqual(r.sink.summaries.count, 2)
    }

    // Repeats of the held key (a non-modifier talk key would repeat) pass to the tool, as in passthrough.
    func testRepeatsWhileFollowingPass() {
        let r = rig()
        r.press(); r.clock.advance(0.5)
        XCTAssertTrue(r.press(), "a repeat")
        XCTAssertEqual(r.engine.machine.state, .following)
        XCTAssertEqual(r.sink.summaries, [])
    }

    // The mic and window samples while held still run (they are off-main), but no chain and no App Nap read: nothing was posted.
    func testSamplesWhileHeldReadMicAndWindowOnly() {
        let r = rig()
        r.probes.micTool = false; r.probes.window = .none("no window (pid 100)")
        let napReadsAtStart = r.probes.processStateReads  // the `started:` line reads it once
        r.press(); r.clock.advance(1.0); r.release(); r.clock.advance(2.6)
        let l = r.sink.summaries.last ?? ""
        XCTAssertTrue(l.contains(" | mic tool off device on, window while held: no window (pid 100) | "), l)
        XCTAssertEqual(r.tap.aheadReads, 0, "the key-listener chain is about a posted key; none was")
        XCTAssertEqual(r.probes.processStateReads - napReadsAtStart, 0, "App Nap is about a posted key too")
        XCTAssertEqual(r.lastEntry()?.cause, .toolDidntListen)
    }

    // A tap or a chord on the talk key (Fn+Delete, the Globe key) is released before the hold delay: not a dictation.
    // The line says so, stats leaves it unjudged, and nothing posted anywhere. Both sides of the threshold.
    func testPressShorterThanTheHoldDelayIsTooShort() {
        let r = rig()
        r.press(); r.clock.advance(0.1); r.release(); r.clock.advance(2.6)
        let l = r.sink.summaries.last ?? ""
        XCTAssertTrue(l.hasSuffix("(follow): held 0.10s, released before fn was held for 0.20s, input source left alone | front=test"), l)
        XCTAssertEqual(r.lastEntry()?.outcome, .tooShort)
        XCTAssertTrue(r.keys.posted.isEmpty)
        XCTAssertEqual(r.sources.selected, [], "the source never became the voice source: nothing to switch back")
        let stats = DictationStats.compute(lines: ["2026-10-19 12:00:00.000 " + l], days: nil, today: "2026-10-19")
        XCTAssertEqual(stats.dictations, 0); XCTAssertEqual(stats.tooShort, 1); XCTAssertNil(stats.successRate)
    }
    func testPressAtTheHoldDelayIsADictation() {
        let r = rig()
        r.press(); r.clock.advance(0.25); r.release(); r.clock.advance(2.6)
        let l = r.sink.summaries.last ?? ""
        XCTAssertTrue(l.contains("(follow): held 0.25s, window never closed after release"), l)
        XCTAssertTrue(l.contains("mic tool ? device ?, window while held: ?"), "released before the first sample: \(l)")
        XCTAssertEqual(r.lastEntry()?.outcome, .noWindow)
    }
    // The talk key is the Globe key too: a tap that switches the input source (macOS "Change Input Source") with no
    // voice window is the user's own switch, and Hijack must not undo it (review round 2, M2).
    func testTooShortPressThatSwitchedTheSourceItselfIsLeftAlone() {
        let r = rig()
        r.press(); r.sources.currentID = Rig.voice; r.clock.advance(0.1); r.release(); r.clock.advance(2.6)
        XCTAssertEqual(r.sources.selected, [], "the user's own switch stays")
        XCTAssertEqual(r.sources.currentID, Rig.voice)
        XCTAssertNil(r.engine.previous)
        let l = r.sink.summaries.last ?? ""
        XCTAssertTrue(l.contains("released before fn was held for 0.20s, input source left alone"), l)
        XCTAssertEqual(r.lastEntry()?.outcome, .tooShort)
    }
    // A too-short press while a restore is pending (a chained press) still restores: the pending restore is the previous dictation's.
    func testTooShortPressWhileWaitingStillRestores() {
        let r = rig()
        r.press(); r.sources.currentID = Rig.voice; r.clock.advance(1.0); r.release(); r.clock.advance(0.3)
        r.press(); r.clock.advance(0.05); r.release()
        XCTAssertEqual(r.engine.previous, Rig.english, "kept across the chain")
        r.clock.advance(2.6)
        XCTAssertEqual(r.sources.selected, [Rig.english])
        XCTAssertTrue(
            (r.sink.summaries.last ?? "").contains("released before fn was held for 0.20s, back after"), r.sink.summaries.last ?? "")
    }

    // Toggle wins over follow: a toggle session needs the posted key, so `follow` is ignored and the line says (toggle).
    func testToggleWinsOverFollow() {
        let r = Rig(toggle: true, follow: true)
        r.press(); r.clock.advance(0.3)
        XCTAssertEqual(r.engine.machine.state, .listening, "a toggle session, with the talk key sent")
        r.echo(); r.release(); r.clock.advance(0.1)
        r.press(); r.clock.advance(2.6)  // the stop tap, then the fallback wait
        XCTAssertEqual(r.keys.count(Rig.fn, down: true), 1)
        let l = r.sink.summaries.last ?? ""
        XCTAssertTrue(l.contains("(toggle): held"), l)
        XCTAssertTrue(l.contains("fn sent after"), l)
        XCTAssertFalse(l.contains("(follow)"), l)
    }

    // A remembered source that outlived its dictation (an interrupted hold dictation, then a same-key passthrough
    // release) must not be read by a later follow-mode press as a restore still pending.
    func testStalePreviousFromAPassthroughReleaseIsDropped() {
        let r = Rig(current: nil)  // hold mode, Fn is both the shortcut and the talk key; no source tracked at start
        r.sources.currentID = Rig.english
        r.pressUntilListening(); r.probes.window = .visible(1); r.release(); r.clock.advance(0.3)
        XCTAssertEqual(r.engine.machine.state, .waitingForText, "setup")
        XCTAssertEqual(r.sources.currentID, Rig.voice, "setup: switched in")
        r.press()  // same key, already in the voice source: passthrough, the previous dictation written up as interrupted
        XCTAssertEqual(r.engine.machine.state, .passthrough)
        r.clock.advance(1.0); r.release()
        XCTAssertEqual(r.engine.machine.state, .idle)
        XCTAssertNil(r.engine.previous, "nothing is pending any more")
        XCTAssertTrue(r.sink.traces.contains { $0.hasPrefix("dropping the remembered input source") })
        r.clock.advance(0.1)  // refresh() runs off the tap
        r.plan.follow = true; r.engine.refresh()
        XCTAssertTrue(r.engine.plan.follow, "setup")
        r.press()
        XCTAssertEqual(r.engine.machine.state, .passthrough, "a plain press inside the voice source, not a chained restore")
        r.release()
        XCTAssertEqual(r.sources.selected, [Rig.voice], "the one switch-in of the first dictation; no restore to a stale source")
    }

    // The input-source reads inside the tap callback at a press (ADR 0011) stay what they were: one for a toggle
    // start or a custom-shortcut hold press (the switch-in's read), none for a toggle stop press; a follow press
    // reads once, and a same-key hold press now shares that read with its switch-in (two on the base).
    func testPressesReadTheInputSourceOnlyWhenTheAnswerIsNeeded() {
        let t = Rig(toggle: true)
        var before = t.sources.reads
        t.press()
        XCTAssertEqual(t.sources.reads - before, 1, "the start press: the switch-in's own read, as before")
        t.clock.advance(0.3); t.release()  // toggle: the release changes nothing; the next press stops
        before = t.sources.reads
        t.press()  // the stop press
        XCTAssertEqual(t.sources.reads - before, 0, "the stop press reads nothing")
        let h = Rig(trigger: KeySpec.named("right_option")!)
        before = h.sources.reads
        h.press()
        XCTAssertEqual(h.sources.reads - before, 1, "a hold press with its own shortcut: the switch-in's read only")
        let f = rig()
        before = f.sources.reads
        f.press()
        XCTAssertEqual(f.sources.reads - before, 1, "one read per follow press, shared by the mode decision and the remembered source")
    }

    // Quit while following: nothing was posted, so nothing to release, and no restore (the process is exiting).
    func testQuitWhileFollowingReleasesNothing() {
        let r = rig()
        r.press(); r.sources.currentID = Rig.voice
        r.engine.stopForQuit()
        XCTAssertTrue(r.keys.posted.isEmpty)
        XCTAssertTrue(r.sink.has("quit: nothing held"))
        // Past the inactive guard (following is active), and the machine left the state alone: nothing to release.
        XCTAssertTrue(r.sink.traces.contains { $0.hasPrefix("quit: following → following") }, "\(r.sink.traces)")
        XCTAssertEqual(r.engine.machine.state, .following)
    }

    // Wake during a follow dictation stops it the usual way: a release, then the watch, then the restore.
    func testWakeDuringFollowStopsAndRestores() {
        let r = rig()
        r.engine.systemWillSleep()
        r.clock.advance(1)
        r.press(); r.sources.currentID = Rig.voice; r.clock.advance(0.5)
        r.engine.sleptAt = r.clock.now.addingTimeInterval(1)  // the sleep came after the press
        r.engine.reconcileAfterWake(.systemWake)
        XCTAssertEqual(r.engine.machine.state, .waitingForText)
        r.clock.advance(2.6)
        XCTAssertEqual(r.sources.selected, [Rig.english])
    }

    // Follow with an app provider (its own hotkey, no input source): nothing to restore, so plain passthrough.
    func testFollowWithAnAppProviderIsPassthrough() {
        let r = Rig(follow: true, switchesInput: false)
        XCTAssertTrue(r.press())
        XCTAssertEqual(r.engine.machine.state, .passthrough)
        r.release()
        XCTAssertEqual(r.sink.summaries, [])
    }

    // MARK: the tool's own switch-in (field, 2026-10-19 19:50: WeType 3.0 swallowed the physical Fn, Hijack saw no key;
    // the one signal was TIS switching Squirrel → WeType)

    /// The system's input source changed to `id`: what the app forwards from TIS's notification.
    private func switchIn(_ r: Rig, to id: String = Rig.voice) { r.sources.currentID = id; r.engine.inputSourceChanged() }

    // A design test, not a field reproduction: the field lines of 20:15 and 20:37 ended by the window (`window seen: 1
    // window`); the per-process mic read off once and on once. This one exercises the mic-only end.
    func testToolSwitchInWithNoKeySeenIsADictationEndedByItsMic() {
        let r = rig()
        XCTAssertEqual(r.engine.lastOtherSource, Rig.english, "tracked from the start")
        switchIn(r)
        XCTAssertEqual(r.engine.machine.state, .waitingForText)
        XCTAssertEqual(r.engine.previous, Rig.english, "from the tracked source: no press told us")
        r.probes.micTool = true  // WeType listens
        r.clock.advance(3.0)
        XCTAssertEqual(r.engine.machine.state, .waitingForText, "live while the mic is on")
        r.probes.micTool = false  // the user stopped talking
        r.clock.advance(0.5)
        XCTAssertEqual(
            r.engine.machine.state, .waitingForText,
            "the mic's grace is longer than the window's (the final text can land after the mic stops)")
        r.clock.advance(Engine.micGrace - 0.5 + 0.3)
        XCTAssertEqual(r.engine.machine.state, .idle)
        XCTAssertEqual(r.sources.selected, [Rig.english], "switched back once")
        XCTAssertTrue(r.keys.posted.isEmpty)
        let l = r.sink.summaries.last ?? ""
        XCTAssertTrue(l.hasPrefix("dictation \(Rig.voice) (follow): switched in by the tool, mic off 3"), l)
        XCTAssertTrue(l.contains("ms after start, back after "), l)
        XCTAssertTrue(l.contains(" | mic tool on device on, window seen: no window (pid 100) | front=test"), l)
        XCTAssertFalse(l.contains("held"), l)
        let e = DictationEntry.parse("2026-10-19 19:50:30.000 " + l)!
        XCTAssertEqual(e.outcome, .textArrived); XCTAssertTrue(e.follow); XCTAssertEqual(e.heldMs, 0); XCTAssertNotNil(e.textInMs)
    }
    // Four notifications came within 30 ms for one switch (field timeline): one dictation, one line.
    func testABurstOfNotificationsForOneSwitchInStartsOneDictation() {
        let r = rig()
        for _ in 0..<4 { switchIn(r) }
        r.probes.micTool = true; r.clock.advance(1.0); r.probes.micTool = false; r.clock.advance(1.5)
        XCTAssertEqual(r.sink.summaries.count, 1, r.sink.summaries.joined(separator: "\n"))
        XCTAssertEqual(r.sources.selected, [Rig.english])
    }
    // 18:36 shape: Hijack saw the key, the tool switched itself in only after the release: the key record is written
    // up, the watch restarts on the tool's signals, and the source remembered at the press is kept.
    func testLateSwitchInWhileWaitingTakesOverAndKeepsTheRememberedSource() {
        let r = rig()
        r.press(); r.clock.advance(2.4); r.release(); r.clock.advance(1.0)
        XCTAssertEqual(r.engine.machine.state, .waitingForText, "setup: the key path's watch, nothing live yet")
        switchIn(r)
        XCTAssertEqual(r.sink.summaries.count, 1)
        XCTAssertTrue(
            (r.sink.summaries.last ?? "").contains(
                "held 2.40s, window never closed after release, the tool switched itself in, followed from here"),
            r.sink.summaries.last ?? "")
        XCTAssertEqual(r.lastEntry()?.outcome, .interrupted)
        XCTAssertEqual(r.engine.previous, Rig.english, "kept across the takeover")
        r.probes.micTool = true; r.clock.advance(2.0); r.probes.micTool = false; r.clock.advance(1.5)
        XCTAssertEqual(r.engine.machine.state, .idle)
        XCTAssertEqual(r.sources.selected, [Rig.english])
        XCTAssertEqual(r.sink.summaries.count, 2)
    }
    // 18:36 shape, later: the key record had already ended (`input source stayed`), then the tool switched in, at the
    // text commit, with nothing live after it (the field readings: no window, mic off). Within restoreTimeout of that
    // end the switch-in belongs to that dictation and goes back, live or not (review round 3, M1).
    func testLateSwitchInAfterTheKeyRecordEndedRestoresEvenWithNothingLive() {
        let r = rig()
        r.sources.currentID = "com.apple.keylayout.US"; r.engine.inputSourceChanged()  // the tracked source differs from the press's
        r.sources.currentID = Rig.english
        r.press(); r.clock.advance(2.4); r.release(); r.clock.advance(2.6)
        XCTAssertEqual(r.engine.machine.state, .idle, "setup")
        XCTAssertTrue((r.sink.summaries.last ?? "").contains("input source stayed"), "setup")
        XCTAssertNil(r.engine.previous)
        r.clock.advance(1.0)
        switchIn(r)  // nothing live follows: no window, mic off
        XCTAssertEqual(r.engine.previous, Rig.english, "the source of the dictation that just ended, not the tracked one")
        XCTAssertTrue(r.sink.has("the tool switched in"), r.sink.lines.joined(separator: "\n"))
        r.clock.advance(2.6)
        XCTAssertEqual(r.sources.selected, [Rig.english], "restored, live or not")
        XCTAssertTrue(
            (r.sink.summaries.last ?? "").contains("switched in by the tool, nothing live within 2.50s, back after"),
            r.sink.summaries.last ?? "")
    }
    func testLateSwitchInBeyondRestoreTimeoutIsLeftAlone() {
        let r = rig()
        r.press(); r.clock.advance(2.4); r.release(); r.clock.advance(2.6)
        r.clock.advance(5.1)  // past restoreTimeout since the line
        switchIn(r); r.clock.advance(2.6)
        XCTAssertEqual(r.sources.selected, [])
        XCTAssertTrue((r.sink.summaries.last ?? "").contains("input source left alone"), r.sink.summaries.last ?? "")
    }
    // A manual switch to the voice source (⌃Space) with no voice after it is the user's: nothing is switched back.
    func testManualSwitchWithNothingLiveIsLeftAlone() {
        let r = rig()
        switchIn(r)
        r.clock.advance(2.6)
        XCTAssertEqual(r.engine.machine.state, .idle)
        XCTAssertEqual(r.sources.selected, [])
        XCTAssertEqual(r.sources.currentID, Rig.voice, "the user stays where they went")
        XCTAssertNil(r.engine.previous)
        let l = r.sink.summaries.last ?? ""
        XCTAssertTrue(l.contains("switched in by the tool, nothing live within 2.50s, input source left alone | mic tool off"), l)
        XCTAssertEqual(r.lastEntry()?.outcome, .tooShort, "not judged")
    }
    // Stuck inside the voice source (a restore was missed): the next follow press still goes back to the tracked source.
    func testPressInsideTheVoiceSourceRestoresToTheTrackedSource() {
        let r = rig()
        switchIn(r); r.clock.advance(2.6)  // a manual switch, left alone: now inside the voice source, idle
        XCTAssertEqual(r.engine.machine.state, .idle, "setup")
        r.press()
        XCTAssertEqual(r.engine.machine.state, .following, "not passthrough: there is somewhere to go back to")
        XCTAssertEqual(r.engine.previous, Rig.english)
        r.probes.window = .visible(1); r.clock.advance(1.0); r.release(); r.clock.advance(0.3)
        r.probes.window = .none("no window (pid 100)"); r.clock.advance(0.5)
        XCTAssertEqual(r.sources.selected, [Rig.english])
    }
    // A process that starts inside the voice source (field, 20:14:57 → 20:15:43: `nothing to switch back to`) takes the
    // persisted last other source, and the tracking writes it for the next process.
    func testAStartInsideTheVoiceSourceTakesThePersistedSourceAndTrackingPersistsIt() {
        let r = Rig(follow: true, current: Rig.voice, start: false)
        r.supervisor.lastOtherSource = "im.rime.inputmethod.Squirrel.Hans"
        r.probes.micTool = false
        r.engine.start()
        XCTAssertEqual(r.engine.lastOtherSource, "im.rime.inputmethod.Squirrel.Hans")
        switchIn(r)  // WeType re-selects itself when its voice starts (the 20:15:43 line came with no other source)
        r.probes.window = .visible(1); r.clock.advance(1.0); r.probes.window = .none("no window (pid 100)"); r.clock.advance(0.4)
        XCTAssertEqual(r.sources.selected, ["im.rime.inputmethod.Squirrel.Hans"])
        XCTAssertTrue((r.sink.summaries.last ?? "").contains("window closed 1"), r.sink.summaries.last ?? "")
        // Tracking writes through on every change of the tracked source (not on a repeat of the same one).
        r.supervisor.lastOtherSource = nil
        r.engine.inputSourceChanged()
        XCTAssertNil(r.supervisor.lastOtherSource, "the same source again: nothing to write")
        r.sources.currentID = Rig.english; r.engine.inputSourceChanged()
        XCTAssertEqual(r.supervisor.lastOtherSource, Rig.english)
        // Nothing persisted and nothing seen: the line says so and nothing is switched.
        let bare = Rig(follow: true, current: Rig.voice); bare.probes.micTool = false
        switchIn(bare); bare.probes.window = .visible(1); bare.clock.advance(1.0); bare.probes.window = .none("x"); bare.clock.advance(0.4)
        XCTAssertEqual(bare.sources.selected, [])
        XCTAssertTrue(
            (bare.sink.summaries.last ?? "").contains("no other input source known yet, nothing to switch back to"),
            bare.sink.summaries.last ?? "")
    }
    // The source read at the press is the truth for that press; the tracked one is only for a press with no other
    // source in it (inside the voice source) or no press at all. A notification can lag or be missed.
    func testTheSourceReadAtThePressWinsOverTheTrackedOne() {
        let r = rig()
        XCTAssertEqual(r.engine.lastOtherSource, Rig.english, "setup: tracked at the start")
        r.sources.currentID = "com.apple.keylayout.US"  // the user switched; no notification reached us
        r.press()
        XCTAssertEqual(r.engine.previous, "com.apple.keylayout.US")
        r.sources.currentID = Rig.voice  // the tool switched itself in
        r.probes.window = .visible(1); r.clock.advance(1.0); r.release(); r.clock.advance(0.3)
        r.probes.window = .none("no window (pid 100)"); r.clock.advance(0.5)
        XCTAssertEqual(r.sources.selected, ["com.apple.keylayout.US"])
    }
    // Hold mode selects the voice source itself: its own switch-in notification starts nothing; the other sources are still tracked.
    func testHoldModeIgnoresItsOwnSwitchInAndTracksTheOtherSources() {
        let r = Rig()
        r.pressUntilListening()
        XCTAssertEqual(r.sources.currentID, Rig.voice, "setup: our switch-in landed")
        let before = r.sink.summaries.count
        r.engine.inputSourceChanged()
        XCTAssertEqual(r.engine.machine.state, .listening)
        XCTAssertEqual(r.sink.summaries.count, before)
        r.sources.currentID = "com.apple.keylayout.US"; r.engine.inputSourceChanged()
        XCTAssertEqual(r.engine.lastOtherSource, "com.apple.keylayout.US")
        // Idle, and the user switches to the voice source by hand: hold mode starts nothing for that either.
        r.release(); r.clock.advance(6)
        XCTAssertEqual(r.engine.machine.state, .idle, "setup")
        let lines = r.sink.summaries.count
        r.sources.currentID = Rig.voice; r.engine.inputSourceChanged()
        XCTAssertEqual(r.engine.machine.state, .idle, "not follow mode: the switch-in is not a dictation")
        r.clock.advance(6)
        XCTAssertEqual(r.sink.summaries.count, lines)
    }
    // The window, once seen, is the better signal: it ends the watch even while the mic still reads on.
    func testAWindowSeenEndsTheWatchEvenWhileTheMicIsOn() {
        let r = rig()
        switchIn(r)
        r.probes.micTool = true; r.probes.window = .visible(1); r.clock.advance(2.0)
        r.probes.window = .none("no window (pid 100)")  // the mic stays on
        r.clock.advance(0.4)
        XCTAssertEqual(r.engine.machine.state, .idle, "capsuleGrace after the window, not micGrace")
        XCTAssertTrue((r.sink.summaries.last ?? "").contains("window closed 2"), r.sink.summaries.last ?? "")
        XCTAssertEqual(r.sources.selected, [Rig.english])
    }
    // A live reading that never ends on the tool path (the tool keeps its mic open, a window that never closes): the
    // watch gives up at maxToolDictation and leaves the source where it is: a switch mid-dictation would lose the text.
    func testAStuckLiveReadingOnTheToolPathGivesUpAndLeavesTheSource() {
        let r = rig()
        switchIn(r); r.probes.micTool = true
        r.clock.advance(Engine.maxToolDictation - 1)
        XCTAssertEqual(r.engine.machine.state, .waitingForText)
        r.clock.advance(1.2)
        XCTAssertEqual(r.engine.machine.state, .idle)
        let l = r.sink.summaries.last ?? ""
        XCTAssertTrue(l.contains("still live 60s after start, gave up, input source left in \(Rig.voice)"), l)
        XCTAssertEqual(r.sources.selected, [])
        XCTAssertEqual(r.lastEntry()?.outcome, .notRestored)
    }
    // The key path counts restoreTimeout from the release, as hold mode does (FM-14): a window that never closes
    // restores 5 s after the release, not 60 s later.
    func testKeyPathWindowThatNeverClosesRestoresAtRestoreTimeout() {
        let r = rig()
        r.press(); r.sources.currentID = Rig.voice; r.probes.window = .visible(1); r.clock.advance(1.0); r.release()
        r.clock.advance(4.9)
        XCTAssertEqual(r.engine.machine.state, .waitingForText)
        r.clock.advance(0.3)
        XCTAssertEqual(r.engine.machine.state, .idle)
        XCTAssertEqual(r.sources.selected, [Rig.english])
        XCTAssertTrue(
            (r.sink.summaries.last ?? "").contains("still live 5s after release, gave up, back after 5."), r.sink.summaries.last ?? "")
    }
    // The tool re-selecting itself right after our restore is logged by name (the W11 symptom would otherwise have no line).
    func testAReselectRightAfterTheRestoreIsLogged() {
        let r = rig()
        r.sources.onSelect = { id in
            r.sources.currentID = id; r.engine.inputSourceChanged()  // the system's notification for our restore
            if id == Rig.english { r.sources.currentID = Rig.voice; r.engine.inputSourceChanged() }  // then the tool takes it back
        }
        switchIn(r); r.probes.micTool = true; r.clock.advance(1.0); r.probes.micTool = false; r.clock.advance(1.5)
        XCTAssertEqual(r.sources.selected.first, Rig.english)
        XCTAssertTrue(r.sink.has("the tool re-selected itself 0ms after the restore"), r.sink.lines.joined(separator: "\n"))
        r.clock.advance(2.6)
        XCTAssertTrue((r.sink.summaries.last ?? "").contains("left alone"), "nothing live after the re-select: left alone, no ping-pong")
        // The restore and switchTo's one retry (it did not stick): nothing after that, whatever the tool re-selects.
        XCTAssertEqual(r.sources.selected, [Rig.english, Rig.english])
        r.clock.advance(10)
        XCTAssertEqual(r.sources.selected.count, 2, "no ping-pong")
    }
    // A watch probe still in flight when the next dictation starts: its completion (which would give up: nothing
    // live, past fallbackDelay) must not end the new dictation's watch.
    func testAStaleWatchCompletionAfterANewPressIsDropped() {
        let r = rig()
        r.clock.deferOffMain = true
        switchIn(r)
        r.clock.advance(0.06)  // the tool record's first poll dispatched its probe (nothing live); the completion is held
        r.press()  // a new dictation (the key path) while that probe is in flight
        XCTAssertEqual(r.engine.machine.state, .following)
        r.sources.currentID = Rig.voice; r.probes.window = .visible(1)
        r.clock.advance(0.3); r.release()
        r.clock.advance(2.6)  // past fallbackDelay for the stale record; the new watch's own probe (window visible) is held too
        XCTAssertEqual(r.engine.machine.state, .waitingForText, "setup")
        r.clock.flushOffMain()  // the stale completion first, then the new one
        XCTAssertEqual(r.engine.machine.state, .waitingForText, "the stale completion did not end the new watch")
        XCTAssertEqual(r.sink.summaries.count, 1, "only the interrupted tool record was written up")
        r.clock.deferOffMain = false
        r.probes.window = .none("no window (pid 100)"); r.clock.advance(0.5)
        XCTAssertEqual(r.sources.selected, [Rig.english], "the new dictation ends on its own signal")
    }
    // A switch-in while the key is held changes nothing: the release starts the watch. A re-select of the tool after
    // the release (a burst member, or the tool re-selecting itself at its voice end) does not split the dictation.
    func testSwitchInWhileTheKeyIsHeldIsAbsorbedAndALaterReselectDoesNotSplit() {
        let r = rig()
        r.press(); r.clock.advance(0.5)
        switchIn(r)
        XCTAssertEqual(r.engine.machine.state, .following)
        XCTAssertEqual(r.sink.summaries, [])
        r.probes.micTool = true; r.clock.advance(1.0); r.release()
        r.clock.advance(0.3); switchIn(r)  // the tool re-selects itself after the release
        XCTAssertEqual(r.sink.summaries, [], "no takeover: the watch is on the tool's signals already")
        r.clock.advance(0.2); r.probes.micTool = false; r.clock.advance(1.5)
        XCTAssertEqual(r.sources.selected, [Rig.english])
        XCTAssertEqual(r.sink.summaries.count, 1)
        XCTAssertTrue((r.sink.summaries.last ?? "").contains("held 1.50s, mic off"), r.sink.summaries.last ?? "")
    }

    // `hijack stats` reads a follow line like any other dictation; a failed one never blames the posted key.
    func testStatsParsesFollowLines() {
        let ok =
            "2026-10-19 18:00:00.000 dictation com.tencent.inputmethod.wetype.pinyin (follow): held 2.93s, window closed 1627ms after release, back after 1.82s | mic tool on device on, window while held: 1 window | front=com.anthropic.claudefordesktop"
        let stayed =
            "2026-10-19 18:01:00.000 dictation com.tencent.inputmethod.wetype.pinyin (follow): held 2.00s, window never closed after release, input source stayed, nothing to switch back | mic tool off device off, window while held: no window (pid 94224) | front=x"
        let unseen =
            "2026-10-19 18:02:00.000 dictation com.tencent.inputmethod.wetype.pinyin (follow): held 2.00s, window never closed after release, back after 2.50s | mic tool on device on, window while held: no window (pid 94224) | front=x"
        let cut =
            "2026-10-19 18:03:00.000 dictation com.tencent.inputmethod.wetype.pinyin (follow): held 1.00s, window never closed after release, interrupted by the next press | mic tool on device on, window while held: 1 window | front=x"
        let e = DictationEntry.parse(ok)!
        XCTAssertTrue(e.follow); XCTAssertFalse(e.toggle)
        XCTAssertEqual(e.outcome, .textArrived); XCTAssertNil(e.cause); XCTAssertNil(e.sentMs); XCTAssertEqual(e.textInMs, 1627)
        XCTAssertNil(e.echoSeen); XCTAssertNil(e.listenersAhead)
        XCTAssertEqual(DictationEntry.parse(stayed)!.outcome, .noWindow)
        XCTAssertEqual(DictationEntry.parse(stayed)!.cause, .toolDidntListen)
        XCTAssertEqual(DictationEntry.parse(unseen)!.cause, .windowNotSeen)
        XCTAssertEqual(DictationEntry.parse(cut)!.outcome, .interrupted)
        let s = DictationStats.compute(lines: [ok, stayed, unseen, cut], days: nil, today: "2026-10-19")
        XCTAssertEqual(s.dictations, 4, "a follow line with no `sent after` is a dictation, not a too-short tap")
        XCTAssertEqual(s.tooShort, 0)
        XCTAssertEqual(s.causes[.keyNotSent, default: 0] + s.causes[.takenAhead, default: 0], 0)
        XCTAssertEqual(s.aheadSampled, 0)
        XCTAssertEqual(s.outcomes[.textArrived], 1); XCTAssertEqual(s.outcomes[.noWindow], 2)
        // Out of range: a hold line is unchanged by the new mode word.
        let hold = ok.replacingOccurrences(of: "(follow): held 2.93s,", with: "(hold): held 2.93s, fn sent after 238ms,")
        XCTAssertFalse(DictationEntry.parse(hold)!.follow)
        XCTAssertEqual(DictationEntry.parse(hold)!.sentMs, 238)
        let decoy = hold.replacingOccurrences(of: "front=com.anthropic.claudefordesktop", with: "front=(follow)")
        XCTAssertTrue(decoy.hasSuffix("front=(follow)"), "setup")
        XCTAssertFalse(DictationEntry.parse(decoy)!.follow, "the mode word in its slot only")
        XCTAssertEqual(s.followed, 4)
        let short =
            "2026-10-19 18:04:00.000 dictation com.tencent.inputmethod.wetype.pinyin (follow): held 0.10s, released before fn was held for 0.20s | front=x"
        XCTAssertEqual(DictationEntry.parse(short)!.outcome, .tooShort)
        let toolOK =
            "2026-10-19 19:50:35.000 dictation com.tencent.inputmethod.wetype.pinyin (follow): switched in by the tool, mic off 3200ms after start, back after 4.21s | mic tool on device on, window seen: no window (pid 94224) | front=x"
        let toolAlone =
            "2026-10-19 19:51:00.000 dictation com.tencent.inputmethod.wetype.pinyin (follow): switched in by the tool, nothing live within 2.50s, input source left alone | mic tool off device off, window seen: no window (pid 94224) | front=x"
        let toolGaveUp =
            "2026-10-19 19:52:00.000 dictation com.tencent.inputmethod.wetype.pinyin (follow): switched in by the tool, still live 60s after start, gave up, back after 60.05s | mic tool on device on, window seen: no window (pid 94224) | front=x"
        let takenOver =
            "2026-10-19 18:36:24.000 dictation com.tencent.inputmethod.wetype.pinyin (follow): held 2.40s, window never closed after release, the tool switched itself in, followed from here | mic tool off device off, window while held: no window (pid 94224) | front=x"
        let notBack =  // the 20:15:43 field line: the text arrived, nothing was switched back
            "2026-10-19 20:15:43.212 dictation com.tencent.inputmethod.wetype.pinyin (follow): switched in by the tool, window closed 968ms after start, input source unreadable at the press, nothing to switch back to | mic tool off device off, window seen: 1 window | front=x"
        let t1 = DictationEntry.parse(toolOK)!
        XCTAssertEqual(t1.outcome, .textArrived); XCTAssertEqual(t1.heldMs, 0); XCTAssertEqual(t1.textInMs, 3200); XCTAssertTrue(t1.follow)
        XCTAssertEqual(DictationEntry.parse(toolAlone)!.outcome, .tooShort)
        XCTAssertEqual(DictationEntry.parse(toolGaveUp)!.outcome, .notRestored, "the tool was live; not seen is false")
        XCTAssertNil(DictationEntry.parse(toolGaveUp)!.cause)
        XCTAssertEqual(DictationEntry.parse(notBack)!.outcome, .notRestored, "in follow mode the restore is the deliverable")
        XCTAssertEqual(DictationEntry.parse(takenOver)!.outcome, .interrupted)
        let ts = DictationStats.compute(lines: [toolOK, toolAlone, toolGaveUp, takenOver, notBack], days: nil, today: "2026-10-19")
        XCTAssertEqual(ts.dictations, 4); XCTAssertEqual(ts.tooShort, 1); XCTAssertEqual(ts.leftAlone, 1); XCTAssertEqual(ts.followed, 4)
        XCTAssertEqual(ts.outcomes[.notRestored], 2)
        XCTAssertEqual(ts.successRate!, 1.0 / 3.0, accuracy: 1e-9, "text arrived and back ÷ (that + no window + not switched back)")
        XCTAssertEqual(DictationStats.compute(lines: [ok], days: nil, today: "2026-10-19").leftAlone, 0)
        XCTAssertEqual(
            DictationStats.compute(lines: [ok, short], days: nil, today: "2026-10-19").followed, 1, "a too-short press is not a dictation")
    }
}
