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
}
