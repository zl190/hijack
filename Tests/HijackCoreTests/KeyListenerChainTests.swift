import XCTest

@testable import HijackCore

// W10 (docs/adr/0023): the pure judge of the system's tap list. Rows are in list order, newest head-inserted tap first.
final class KeyListenerChainTests: XCTestCase {
    static let us: pid_t = 500
    func row(_ pid: pid_t, hid: Bool = true, enabled: Bool = true, filtering: Bool = true, flags: Bool = true, keys: Bool = true)
        -> TapRow
    {
        TapRow(pid: pid, hidLevel: hid, enabled: enabled, filtering: filtering, watchesFlags: flags, watchesKeys: keys)
    }
    let names: [pid_t: String] = [100: "WeType", 200: "LinearMouse", 300: "Newcomer", 500: "Hijack"]
    /// Processes 100 and 200 started before us; 300 after; anything else unknown.
    func judge(_ rows: [TapRow], modifierKey: Bool = true) -> KeyListenerChain {
        keyListenerChain(
            rows: rows, ours: Self.us, modifierKey: modifierKey, name: { self.names[$0] ?? "pid \($0)" },
            startedBeforeUs: { [100: true, 200: true, 300: false][$0] })
    }

    // In range: an older process's enabled, filtering, HID-level tap for our event type, listed before ours.
    func testOlderFilteringListenerBeforeOursIsNamedInOrder() {
        XCTAssertEqual(judge([row(100), row(200), row(Self.us), row(300)]), .ahead(["WeType", "LinearMouse"]))
    }
    func testOursFirstIsAheadNone() {
        XCTAssertEqual(judge([row(Self.us), row(100), row(200)]), .ahead([]))
    }
    // Out of range, one per condition.
    func testListedAfterOursIsNotNamed() {
        XCTAssertEqual(judge([row(Self.us), row(100)]), .ahead([]))
    }
    func testListenOnlyTapIsNotNamed() {
        XCTAssertEqual(judge([row(100, filtering: false), row(Self.us)]), .ahead([]))
    }
    func testSessionLevelTapIsNotNamed() {
        XCTAssertEqual(judge([row(100, hid: false), row(Self.us)]), .ahead([]))
    }
    func testDisabledTapIsNotNamed() {
        XCTAssertEqual(judge([row(100, enabled: false), row(Self.us)]), .ahead([]))
    }
    func testYoungerProcessAheadIsNotNamed() {
        XCTAssertEqual(judge([row(300), row(Self.us)]), .ahead([]), "a relaunch puts us back in front of it")
    }
    func testUnknownStartCountsAsOlder() {
        XCTAssertEqual(judge([row(900), row(Self.us)]), .ahead(["pid 900"]))
    }
    // The talk key's event type decides which taps matter: Fn is a flagsChanged, a plain key is a keyDown.
    func testKeysOnlyTapCannotTakeAModifierKey() {
        XCTAssertEqual(judge([row(100, flags: false, keys: true), row(Self.us)]), .ahead([]))
    }
    func testFlagsOnlyTapCannotTakeAPlainKey() {
        XCTAssertEqual(judge([row(100, flags: true, keys: false), row(Self.us)], modifierKey: false), .ahead([]))
        XCTAssertEqual(judge([row(100, flags: false, keys: true), row(Self.us)], modifierKey: false), .ahead(["WeType"]))
    }
    func testOurOtherTapsAndRepeatedNamesCountOnce() {
        XCTAssertEqual(judge([row(100), row(Self.us), row(100), row(Self.us)]), .ahead(["WeType"]))
        XCTAssertEqual(judge([row(100), row(100), row(Self.us)]), .ahead(["WeType"]))
    }
    // Ours missing, disabled, or watching the wrong event: not listed, which is not "nobody ahead".
    func testOursAbsentIsNotListed() {
        XCTAssertEqual(judge([row(100)]), .notListed)
        XCTAssertEqual(judge([row(100), row(Self.us, enabled: false)]), .notListed)
        XCTAssertEqual(judge([row(100), row(Self.us, flags: false)]), .notListed)
    }
    // Names must survive the `ahead:` field: no separators, never a field token.
    func testNamesAreMadeSafeForTheField() {
        XCTAssertEqual(safeListenerName("We+Type, v|2"), "We_Type_ v_2")
        XCTAssertEqual(safeListenerName("none"), "none_")
        XCTAssertEqual(safeListenerName("?"), "?_")
        XCTAssertEqual(safeListenerName(""), "_")
        XCTAssertEqual(safeListenerName("WeType"), "WeType")
        let r = keyListenerChain(
            rows: [row(100), row(Self.us)], ours: Self.us, modifierKey: true, name: { _ in "a+b" }, startedBeforeUs: { _ in true })
        XCTAssertEqual(r, .ahead(["a_b"]))
    }
}
