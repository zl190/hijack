import XCTest
@testable import HijackCore

// HCI review: fault signals (docs/hci-review-faults.md §5, items 1-4). Each test names the row it covers.

final class MenuStateTests: XCTestCase {

    // §3.1: once the tap has had a chance to install, the icon is Off whenever either fact is missing,
    // Idle only when both hold.
    func testIconIsOffUnlessBothTrustedAndTapActive() {
        XCTAssertEqual(IconState.of(trusted: true, tapActive: true, tapInstalled: true), .idle)
        XCTAssertEqual(IconState.of(trusted: true, tapActive: false, tapInstalled: true), .off)
        XCTAssertEqual(IconState.of(trusted: false, tapActive: true, tapInstalled: true), .off)
        XCTAssertEqual(IconState.of(trusted: false, tapActive: false, tapInstalled: true), .off)
    }

    // review-4 M1: before the tap has ever been installed (the moment between applyAppearance() and
    // engine.start() on every normal launch), tapActive is necessarily false — that must read as Idle,
    // not as the FM-02 fault, or every launch flashes "Off".
    func testIconIsIdleBeforeTheTapHasBeenInstalled() {
        XCTAssertEqual(IconState.of(trusted: true, tapActive: false, tapInstalled: false), .idle)
    }

    // Missing Accessibility is still Off even before the tap is installed (it never will be).
    func testIconIsOffWithoutAccessibilityEvenBeforeInstall() {
        XCTAssertEqual(IconState.of(trusted: false, tapActive: false, tapInstalled: false), .off)
    }

    // §3.2: no fault, no line.
    func testFirstLineIsNilWithNoFault() {
        XCTAssertNil(MenuFaults.firstLine(tapActive: true, stillHoldingTalkKey: nil))
    }

    // FM-02: a dead key listener wins over everything else.
    func testKeyListenerOffWinsOverStillHolding() {
        XCTAssertEqual(MenuFaults.firstLine(tapActive: false, stillHoldingTalkKey: "Fn"), .keyListenerOff)
    }

    // FM-01/04/25: a stuck session, with the physical key already up, shows when the key listener is fine.
    func testStillHoldingShowsWhenKeyListenerIsFine() {
        XCTAssertEqual(MenuFaults.firstLine(tapActive: true, stillHoldingTalkKey: "Fn"), .stillHolding(talkKey: "Fn"))
    }

    // FM-03: shows alone when it's the only thing wrong.
    func testSecureInputShowsAlone() {
        XCTAssertEqual(MenuFaults.firstLine(tapActive: true, secureInputApp: "Terminal"), .secureInput(app: "Terminal"))
    }

    // A stuck session outranks Secure Input (it traps the very next press).
    func testStillHoldingWinsOverSecureInput() {
        XCTAssertEqual(MenuFaults.firstLine(tapActive: true, stillHoldingTalkKey: "Fn", secureInputApp: "Terminal"), .stillHolding(talkKey: "Fn"))
    }

    // A dead key listener wins over both of the others at once.
    func testKeyListenerOffWinsOverEverything() {
        XCTAssertEqual(MenuFaults.firstLine(tapActive: false, stillHoldingTalkKey: "Fn", secureInputApp: "Terminal"), .keyListenerOff)
    }

    // review-4 M3: the "still holding" condition, moved into Core so it's testable without AppKit.
    // Toggle mode has the shortcut up for the whole, normal dictation — that is not the fault this line
    // reports, so toggle never shows it, active or not.
    func testStillHoldingTalkKey_ToggleActiveShowsNoLine() {
        XCTAssertNil(MenuFaults.stillHoldingTalkKey(toggle: true, isActive: true, keyIsPhysicallyDown: false, talkKeyName: "Fn"))
    }

    // Hold mode, active, the live key reads up: this is the exact stuck case (a missed release).
    func testStillHoldingTalkKey_HoldActiveKeyUpShowsTheLine() {
        XCTAssertEqual(MenuFaults.stillHoldingTalkKey(toggle: false, isActive: true, keyIsPhysicallyDown: false, talkKeyName: "Fn"), "Fn")
    }

    // Hold mode, active, the live key still reads down: a normal in-progress dictation, no line.
    func testStillHoldingTalkKey_HoldActiveKeyDownShowsNoLine() {
        XCTAssertNil(MenuFaults.stillHoldingTalkKey(toggle: false, isActive: true, keyIsPhysicallyDown: true, talkKeyName: "Fn"))
    }

    // Not active: never shows, whatever the key state.
    func testStillHoldingTalkKey_NotActiveShowsNoLine() {
        XCTAssertNil(MenuFaults.stillHoldingTalkKey(toggle: false, isActive: false, keyIsPhysicallyDown: false, talkKeyName: "Fn"))
    }
}

final class HCIFaultsTests: XCTestCase {

    // FM-24, revoked while running: Accessibility goes away, the tap gets disabled, and the re-enable
    // path must not pretend a retry could fix it — it writes state.json false/false instead (§1).
    func testFM24_AccessibilityRevokedWhileRunningWritesState() {
        let r = Rig()
        r.tap.trusted = false
        _ = r.engine.handle(KeyInput(kind: .tapDisabledByTimeout))
        r.clock.advance(0)   // the write is off the tap callback, one tick later (review-4 M2)
        XCTAssertTrue(r.sink.has("Accessibility permission is gone"))
        XCTAssertEqual(r.sink.states.last.map { [$0.trusted, $0.tapActive] }, [false, false])
    }

    // review-4 M2: the Accessibility guard must not do file I/O (via sink.state -> AppState.write) inside
    // the tap callback. Zero state writes while the event is handled; one on the next run-loop turn.
    func testFM24_StateWriteIsOffTheTapCallback() {
        let r = Rig()
        let before = r.sink.states.count
        r.tap.trusted = false
        _ = r.engine.handle(KeyInput(kind: .tapDisabledByTimeout))
        XCTAssertEqual(r.sink.states.count, before, "no state write inside the callback")
        r.clock.advance(0)
        XCTAssertEqual(r.sink.states.count, before + 1, "exactly one, on the next tick")
        XCTAssertEqual(r.sink.states.last.map { [$0.trusted, $0.tapActive] }, [false, false])
    }

    // §3.2 "still holding": the physical key is up, but the engine still thinks a hold-mode session is
    // active. The menu's click path stops it the same way reconcileAfterWake does.
    func testStopStuckSession_HoldMode() {
        let r = Rig()
        r.pressUntilListening()
        r.engine.physicalDown = false   // the keyboard already has it up; only our bookkeeping is stuck
        XCTAssertTrue(r.engine.machine.isActive, "setup: still active")
        r.engine.stopStuckSession()
        XCTAssertEqual(r.engine.machine.state, .waitingForText)
    }

    // review-4 M3: after the stop, physicalDown must match the live key state, or the user's next real
    // press is read as a repeat of a press that never happened and gets swallowed.
    func testStopStuckSession_ResyncsPhysicalDownToTheLiveKeyState() {
        let r = Rig()
        r.pressUntilListening()
        r.engine.physicalDown = true   // stale: the tap missed the release, the keyboard already has it up
        r.tap.keysDown = []             // the live keyboard state: up
        r.engine.stopStuckSession()
        XCTAssertFalse(r.engine.physicalDown, "resynced to the live key state, like reconcileAfterWake")
    }

    // Toggle mode: the same call presses (stop by press), not releases.
    func testStopStuckSession_ToggleMode() {
        let r = Rig(toggle: true)
        r.pressUntilListening()
        r.engine.physicalDown = false
        r.engine.stopStuckSession()
        XCTAssertEqual(r.engine.machine.state, .waitingForText)
    }

    // Nothing active: a stray call does nothing (no spurious effects).
    func testStopStuckSession_NoSessionDoesNothing() {
        let r = Rig()
        let tracesBefore = r.sink.traces.count
        r.engine.stopStuckSession()
        // State and posted keys alone don't prove the guard ran: run(.release) in .idle only swallows the
        // key and stays .idle either way (review-4: "vacuous"). engine.run() always traces once when it's
        // called, so an unchanged trace count proves run() was never reached.
        XCTAssertEqual(r.sink.traces.count, tracesBefore, "run() must not be called when nothing is active")
        XCTAssertEqual(r.engine.machine.state, .idle)
        XCTAssertEqual(r.keys.posted.count, 0)
    }

    // FM-10 at the source: quitting while a session is active must release the talk key before the process
    // exits, synchronously (no waitingForText poll — there is no time left for one). AppDelegate.applicationWillTerminate
    // calls engine.stopForQuit(), the same Engine path used by stopStuckSession and reconcileAfterWake.
    func testStopForQuit_ListeningReleasesTheTalkKeyOnce() {
        let r = Rig()
        r.pressUntilListening()
        r.engine.stopForQuit()
        XCTAssertEqual(r.keys.count(Rig.fn, down: false), 1, "exactly one release")
        XCTAssertEqual(r.engine.machine.state, .idle)
    }

    // M1 (docs/review-4/hardening-review.md): a tap/doubleTap tool's stop key normally goes out through
    // tapKey(), scheduled with clock.after — DispatchQueue.main.asyncAfter on the live Scheduler. But
    // terminate() calls exit() right after applicationWillTerminate returns, so a scheduled post never
    // runs. Quit must post the stop tap synchronously, with no clock advance.
    func testStopForQuit_TapStyleIsPostedSynchronouslyWithNoClockAdvance() {
        let r = Rig(start: false)
        r.plan.style = "tap"
        r.engine.start()
        r.pressUntilListening(echo: false)
        let before = r.keys.posted.count
        r.engine.stopForQuit()
        XCTAssertEqual(r.keys.posted[before...].map(\.down), [true, false], "the stop tap's down and up")
        XCTAssertEqual(r.engine.machine.state, .idle)
    }

    func testStopForQuit_DoubleTapStyleIsPostedSynchronouslyWithNoClockAdvance() {
        let r = Rig(start: false)
        r.plan.style = "doubleTap"
        r.engine.start()
        r.pressUntilListening(echo: false)
        let before = r.keys.posted.count
        r.engine.stopForQuit()
        XCTAssertEqual(r.keys.posted[before...].map(\.down), [true, false, true, false], "two full taps")
        XCTAssertEqual(r.engine.machine.state, .idle)
    }

    // Out-of-range: nothing active (idle) when the app quits, so nothing is posted.
    func testStopForQuit_IdleDoesNothing() {
        let r = Rig()
        let tracesBefore = r.sink.traces.count
        r.engine.stopForQuit()
        XCTAssertEqual(r.sink.traces.count, tracesBefore, "run() must not be called when nothing is active")
        XCTAssertEqual(r.engine.machine.state, .idle)
        XCTAssertEqual(r.keys.posted.count, 0)
    }

    // FM-09: the probe reads the tool's mic "off" for >= 1s while the key is held; "Try it" must say so.
    // (The first sample fires 0.3s after the talk key goes out, itself ~0.2s (holdDelay) after the press.)
    func testFM09_MicOffForASecondReportsNotListening() {
        let r = Rig()
        r.probes.micTool = false
        r.press(); r.clock.advance(0.52)               // first sample: mic off starts now
        XCTAssertFalse(r.sink.reports.contains { $0.phase == "notListening" }, "not yet 1s")
        r.clock.advance(0.5)                           // second sample: ~0.5s since the mic first read off
        XCTAssertFalse(r.sink.reports.contains { $0.phase == "notListening" })
        r.clock.advance(0.5)                           // third sample: ~1.0s since the mic first read off
        XCTAssertTrue(r.sink.reports.contains { $0.phase == "notListening" && $0.detail == "WeType" })
    }

    // A quick blip (recovers before 1s) never reports anything.
    func testFM09_ABriefMicBlipDoesNotReport() {
        let r = Rig()
        r.probes.micTool = false
        r.press(); r.clock.advance(0.52)
        r.probes.micTool = true
        r.clock.advance(0.5)
        XCTAssertFalse(r.sink.reports.contains { $0.phase == "notListening" })
    }

    // FM-12 control: an unknown ("nil") reading never claims the tool isn't listening.
    func testFM09_UnknownMicNeverReportsNotListening() {
        let r = Rig()
        r.probes.micTool = nil
        r.press(); r.clock.advance(0.52); r.clock.advance(0.5); r.clock.advance(0.5)
        XCTAssertFalse(r.sink.reports.contains { $0.phase == "notListening" })
    }

    // FM-16: "Try it" must not say "back to X" before the restore is confirmed, and must say so honestly
    // once it is confirmed (the normal, successful case).
    func testFM16_DoneReportWaitsForConfirmationThenConfirms() {
        let r = Rig()
        r.pressUntilListening(); r.release()
        r.clock.advance(2.4)   // short of fallbackDelay (2.5): the dictation hasn't ended yet
        XCTAssertFalse(r.sink.reports.contains { $0.phase == "done" }, "not before fallbackDelay")
        // review-4: at 2.4s the old code is ALSO silent (finish() itself hasn't run yet), so that
        // assertion alone passes on a revert. The discriminating moment is here: past fallbackDelay
        // (finish() has run and started the restore) but before the 0.1s confirm it waits on.
        r.clock.advance(0.2)   // cumulative ~2.6s: finish() has run; the 0.1s confirm has not
        XCTAssertFalse(r.sink.reports.contains { $0.phase == "done" }, "not before the 0.1s confirm")
        r.clock.advance(0.3)   // past the confirm
        let done = r.sink.reports.last { $0.phase == "done" }
        XCTAssertTrue(done?.detail.contains("back to") == true, done?.detail ?? "nil")
    }

    // review-4 S1: a sample dispatched while listening can complete after the release. Its stale result
    // must not overwrite whatever "Try it" text the release itself produced.
    func testS1_SampleCompletingAfterReleaseDoesNotReport() {
        let r = Rig()
        r.probes.micTool = false
        r.pressUntilListening(hold: 0.6, echo: false)   // exactly one sample has completed; micOffSince is set
        r.probes.micTool = true                          // the tool "recovers" — the next sample would report it
        r.clock.deferOffMain = true
        r.clock.advance(0.5)                              // the second sample's work runs; its completion is held
        r.release()
        let lastPhaseAfterRelease = r.sink.reports.last?.phase
        r.clock.flushOffMain()                            // now let the held (stale) completion run
        XCTAssertEqual(r.sink.reports.last?.phase, lastPhaseAfterRelease, "a stale sample must not report after release")
    }

    // FM-16: when the restore never sticks (even after the retry), the report must not claim success.
    func testFM16_DoneReportSaysSoWhenNotConfirmed() {
        let r = Rig()
        r.sources.refuse = [Rig.english]
        r.pressUntilListening(); r.release()
        r.clock.advance(2.8)
        let done = r.sink.reports.last { $0.phase == "done" }
        XCTAssertEqual(done?.detail, "Didn't switch back; the input source is still WeType")
    }
}

// review-5 #3: refresh() rebuilds the Plan, and a provider's detected() reads a settings file from disk
// (WeType's MMKV, Handy's JSON). An app tool (switchesInput == false) reaches idle inside the tap's own
// key event on every release, so that read used to happen synchronously inside the tap callback.
extension HCIFaultsTests {
    func testRefreshPlan_IsDeferredOffTheReleaseInAppMode() {
        let r = Rig(switchesInput: false, trigger: KeySpec.named("right_option")!)
        r.pressUntilListening()
        let before = r.planReads
        r.release()
        XCTAssertEqual(r.planReads, before, "no plan (file) read synchronously inside the key event")
        r.clock.advance(0)
        XCTAssertEqual(r.planReads, before + 1, "exactly one refresh after the tick")
    }

    // Out-of-range: a release that does not reach idle (toggle mode, still listening) must not schedule
    // a refresh at all.
    func testRefreshPlan_ToggleReleaseStayingActiveSchedulesNothing() {
        let r = Rig(toggle: true, switchesInput: false, trigger: KeySpec.named("right_option")!)
        r.pressUntilListening()
        let before = r.planReads
        r.release()   // toggle: releasing the trigger alone keeps the session running
        XCTAssertEqual(r.engine.machine.state, .listening, "setup: toggle keeps going")
        r.clock.advance(0)
        XCTAssertEqual(r.planReads, before, "still active: nothing to refresh")
    }
}

// review-5 #17: the summary line must carry stable identifiers, not display names that change with the
// language, or hijack stats splits one tool into two after a language switch (Stats.swift groups by this
// line's leading field).
extension HCIFaultsTests {
    func testSummaryLine_CarriesStableIdsNotLocalizedNames() {
        let r = Rig()
        r.pressUntilListening(); r.release(); r.clock.advance(2.6)
        let line = r.sink.summaries.last ?? ""
        XCTAssertTrue(line.hasPrefix("dictation \(Rig.voice) ("), line)
        XCTAssertTrue(line.contains("\(Rig.fn.logID) sent after"), line)
        XCTAssertFalse(line.contains("WeType"), "the localized display name must not be on the line: \(line)")
    }

    // Out-of-range: released before the talk key went out still names the key by its stable id, not "Fn".
    // App mode (switchesInput: false) finishes synchronously on this release, no clock advance needed.
    func testSummaryLine_TooShortAlsoUsesTheStableKeyId() {
        let r = Rig(switchesInput: false, trigger: KeySpec.named("right_option")!)
        r.press(); r.release()
        let line = r.sink.summaries.last ?? ""
        XCTAssertTrue(line.contains("released before \(Rig.fn.logID) was sent"), line)
    }
}
