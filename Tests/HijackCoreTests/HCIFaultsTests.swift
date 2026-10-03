import XCTest
@testable import HijackCore

// HCI review: fault signals (docs/hci-review-faults.md §5, items 1-4). Each test names the row it covers.

final class MenuStateTests: XCTestCase {

    // §3.1: the icon is Off whenever either fact is missing, Idle only when both hold.
    func testIconIsOffUnlessBothTrustedAndTapActive() {
        XCTAssertEqual(IconState.of(trusted: true, tapActive: true), .idle)
        XCTAssertEqual(IconState.of(trusted: true, tapActive: false), .off)
        XCTAssertEqual(IconState.of(trusted: false, tapActive: true), .off)
        XCTAssertEqual(IconState.of(trusted: false, tapActive: false), .off)
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
}

final class HCIFaultsTests: XCTestCase {

    // FM-24, revoked while running: Accessibility goes away, the tap gets disabled, and the re-enable
    // path must not pretend a retry could fix it — it writes state.json false/false instead (§1).
    func testFM24_AccessibilityRevokedWhileRunningWritesState() {
        let r = Rig()
        r.tap.trusted = false
        _ = r.engine.handle(KeyInput(kind: .tapDisabledByTimeout))
        XCTAssertTrue(r.sink.has("Accessibility permission is gone"))
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
        r.engine.stopStuckSession()
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
        XCTAssertFalse(r.sink.reports.contains { $0.phase == "done" }, "not before the 0.1s confirm")
        r.clock.advance(0.4)   // past fallbackDelay, and past the 0.1s confirm that follows it
        let done = r.sink.reports.last { $0.phase == "done" }
        XCTAssertTrue(done?.detail.contains("back to") == true, done?.detail ?? "nil")
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
