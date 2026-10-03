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
        XCTAssertNil(MenuFaults.firstLine(tapActive: true))
    }

    // FM-02: a dead key listener is the one fault this item adds.
    func testKeyListenerOffIsTheFault() {
        XCTAssertEqual(MenuFaults.firstLine(tapActive: false), .keyListenerOff)
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
}
