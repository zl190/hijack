import XCTest

@testable import HijackCore

final class DictationModeTests: XCTestCase {
    func testAutoFollowsAToolThatTakesItsOwnKeyAndHoldsOtherwise() {
        XCTAssertEqual(DictationMode.resolve(configured: "auto", toolTakesTalkKey: true), "follow")
        XCTAssertEqual(DictationMode.resolve(configured: "auto", toolTakesTalkKey: false), "hold")
    }
    func testAnExplicitModeIsKeptWhateverTheToolDoes() {
        for mode in ["hold", "toggle", "follow"] {
            XCTAssertEqual(DictationMode.resolve(configured: mode, toolTakesTalkKey: true), mode)
            XCTAssertEqual(DictationMode.resolve(configured: mode, toolTakesTalkKey: false), mode)
        }
    }
    func testAnUnknownValueCountsAsAuto() {
        XCTAssertEqual(DictationMode.resolve(configured: "", toolTakesTalkKey: true), "follow")
        XCTAssertEqual(DictationMode.resolve(configured: "banana", toolTakesTalkKey: false), "hold")
        for v in ["auto", "", "banana"] { XCTAssertTrue(DictationMode.isAuto(v), v) }
        for v in DictationMode.explicit { XCTAssertFalse(DictationMode.isAuto(v), v) }
        XCTAssertEqual(DictationMode.all, ["auto", "hold", "toggle", "follow"])
    }
    // 2.2.3 (657) was the last WeType where hold mode worked; 3.0.0 (670) swallows the key (incident 2026-10-19).
    func testWeTypeVersionGate() {
        XCTAssertFalse(DictationMode.weTypeTakesTalkKey(version: "2.2.3"))
        XCTAssertFalse(DictationMode.weTypeTakesTalkKey(version: "2.9.9"))
        XCTAssertTrue(DictationMode.weTypeTakesTalkKey(version: "3.0.0"))
        XCTAssertTrue(DictationMode.weTypeTakesTalkKey(version: "3"))
        XCTAssertTrue(DictationMode.weTypeTakesTalkKey(version: "3.1"))
        XCTAssertTrue(DictationMode.weTypeTakesTalkKey(version: "10.0.0"), "numeric, not lexical")
        XCTAssertFalse(DictationMode.weTypeTakesTalkKey(version: nil), "not installed or unreadable: assume the old behaviour")
    }
    func testVersionCompareIsNumericPerComponent() {
        XCTAssertEqual(DictationMode.compareVersions("3.0.0", "3"), 0)
        XCTAssertEqual(DictationMode.compareVersions("2.10", "2.9"), 1)
        XCTAssertEqual(DictationMode.compareVersions("2.2.3", "3.0.0"), -1)
    }
}
