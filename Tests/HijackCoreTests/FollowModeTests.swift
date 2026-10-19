import XCTest

@testable import HijackCore

// W11 (docs/adr/0024-follow-mode.md): the voice tool starts itself on its own physical talk key; Hijack never posts a
// key and only switches the input source back after the text landed. Evidence for why: docs/incidents/2026-10-04-echo-missing.md,
// section 2026-10-19 (WeType 3.0 swallows a posted Fn and acts on a physical one).
final class FollowModeTests: XCTestCase {
    /// A follow-mode rig: Fn is the trigger and the talk key, the user types in English.
    private func rig(current: String? = Rig.english) -> Rig { Rig(follow: true, current: current) }

    // The whole dictation: press (WeType switches itself in), speak, release, its window goes, Hijack switches back.
    func testRestoresThePreviousSourceAfterTheToolsWindowCloses() {
        let r = rig()
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
        XCTAssertTrue(l.hasSuffix("(follow): held 0.10s, released before fn was held for 0.20s | front=test"), l)
        XCTAssertEqual(r.lastEntry()?.outcome, .tooShort)
        XCTAssertTrue(r.keys.posted.isEmpty)
        XCTAssertEqual(r.sources.selected, [], "the source never became the voice source: nothing to switch back")
        let stats = DictationStats.compute(lines: ["2026-10-19 12:00:00.000 " + l], days: nil, today: "2026-10-19")
        XCTAssertEqual(stats.dictations, 0); XCTAssertEqual(stats.tooShort, 1); XCTAssertNil(stats.successRate)
    }
    func testPressAtTheHoldDelayIsADictation() {
        let r = rig()
        r.press(); r.clock.advance(0.2); r.release(); r.clock.advance(2.6)
        let l = r.sink.summaries.last ?? ""
        XCTAssertTrue(l.contains("(follow): held 0.20s, window never closed after release"), l)
        XCTAssertTrue(l.contains("mic tool ? device ?, window while held: ?"), "released before the first sample: \(l)")
        XCTAssertEqual(r.lastEntry()?.outcome, .noWindow)
    }
    // A too-short press while a restore is pending still restores, as a too-short hold-mode press does.
    func testTooShortPressWhileWaitingStillRestores() {
        let r = rig()
        r.press(); r.sources.currentID = Rig.voice; r.clock.advance(1.0); r.release(); r.clock.advance(0.3)
        r.press(); r.clock.advance(0.05); r.release()
        XCTAssertEqual(r.engine.previous, Rig.english, "kept across the chain")
        r.clock.advance(2.6)
        XCTAssertEqual(r.sources.selected, [Rig.english])
        XCTAssertTrue((r.sink.summaries.last ?? "").contains("released before fn was held"), r.sink.summaries.last ?? "")
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
        let r = Rig()  // hold mode, Fn is both the shortcut and the talk key
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

    // The input-source reads inside the tap callback at a press (ADR 0011) stay what they were: one for a
    // press that switches in (to remember the source), none for a toggle stop press; a follow press reads once.
    func testPressesReadTheInputSourceOnlyWhenTheAnswerIsNeeded() {
        let t = Rig(toggle: true)
        var before = t.sources.reads
        t.press()
        XCTAssertEqual(t.sources.reads - before, 1, "the start press: the switch-in's own read, as before")
        t.clock.advance(0.3)
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
        XCTAssertFalse(
            DictationEntry.parse(hold.replacingOccurrences(of: "front=x", with: "front=(follow)"))!.follow, "the mode word in its slot only"
        )
        XCTAssertEqual(s.followed, 4)
        let short =
            "2026-10-19 18:04:00.000 dictation com.tencent.inputmethod.wetype.pinyin (follow): held 0.10s, released before fn was held for 0.20s | front=x"
        XCTAssertEqual(DictationEntry.parse(short)!.outcome, .tooShort)
        XCTAssertEqual(
            DictationStats.compute(lines: [ok, short], days: nil, today: "2026-10-19").followed, 1, "a too-short press is not a dictation")
    }
}
