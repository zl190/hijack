import XCTest
@testable import HijackCore

// `hijack version` reads the version Sparkle found last; it never checks the network itself.
final class UpdateNoticeTests: XCTestCase {
    func testNewerFoundVersionIsReported() {
        XCTAssertEqual(UpdateNotice.line(running: "1.2.0", found: "1.2.1", skipped: nil), "update available: 1.2.1")
    }
    func testSameVersionIsNotReported() {
        XCTAssertNil(UpdateNotice.line(running: "1.2.1", found: "1.2.1", skipped: nil))
    }
    func testOlderFoundVersionIsNotReported() {
        XCTAssertNil(UpdateNotice.line(running: "1.2.1", found: "1.2.0", skipped: nil), "the feed can lag behind a source build")
    }
    func testSkippedVersionIsNamedAsSkipped() {
        XCTAssertEqual(UpdateNotice.line(running: "1.2.0", found: "1.2.1", skipped: "1.2.1"), "update available: 1.2.1 (skipped)")
    }
    func testSkippedOtherVersionDoesNotHideANewerOne() {
        XCTAssertEqual(UpdateNotice.line(running: "1.2.0", found: "1.2.2", skipped: "1.2.1"), "update available: 1.2.2")
    }
    func testNothingFoundPrintsNothing() {
        XCTAssertNil(UpdateNotice.line(running: "1.2.0", found: nil, skipped: nil))
    }
    func testNumericCompareNotLexical() {
        XCTAssertEqual(UpdateNotice.line(running: "1.9.0", found: "1.10.0", skipped: nil), "update available: 1.10.0")
        XCTAssertNil(UpdateNotice.line(running: "1.10.0", found: "1.9.0", skipped: nil))
    }
    func testShorterVersionIsPaddedWithZeros() {
        XCTAssertNil(UpdateNotice.line(running: "1.2", found: "1.2.0", skipped: nil))
        XCTAssertEqual(UpdateNotice.line(running: "1.2", found: "1.2.1", skipped: nil), "update available: 1.2.1")
    }
}
