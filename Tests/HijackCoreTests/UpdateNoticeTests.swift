import XCTest
@testable import HijackCore

// `hijack version` reads the update the app recorded at its last check; it never checks the network itself.
// `found` carries the display version (CFBundleShortVersionString) and the build (sparkle:version);
// Sparkle stores a skipped update by its build string, so skips compare build with build.
final class UpdateNoticeTests: XCTestCase {
    /// A found update whose build string equals its display version, as Hijack's builds are today.
    func f(_ v: String) -> UpdateFound { UpdateFound(display: v, build: v) }

    func testFoundVersionEqualToTheRunningBuildPrintsNothing() {
        XCTAssertNil(UpdateNotice.line(running: "1.2.0", found: UpdateFound(display: "1.2.0", build: "1.2.0.77"), skippedBuild: nil))
    }
    func testSkippedComparesBuildWithBuild() {
        let found = UpdateFound(display: "1.2.1", build: "1.2.1.90")
        XCTAssertEqual(UpdateNotice.line(running: "1.2.0", found: found, skippedBuild: "1.2.1.90"), "update available: 1.2.1 (skipped)")
        XCTAssertEqual(UpdateNotice.line(running: "1.2.0", found: found, skippedBuild: "1.2.1"), "update available: 1.2.1",
                       "a display string in the skip slot must not match")
    }
    func testNewerFoundVersionIsReported() {
        XCTAssertEqual(UpdateNotice.line(running: "1.2.0", found: f("1.2.1"), skippedBuild: nil), "update available: 1.2.1")
    }
    func testSameVersionIsNotReported() {
        XCTAssertNil(UpdateNotice.line(running: "1.2.1", found: f("1.2.1"), skippedBuild: nil))
    }
    func testOlderFoundVersionIsNotReported() {
        XCTAssertNil(UpdateNotice.line(running: "1.2.1", found: f("1.2.0"), skippedBuild: nil), "the feed can lag behind a source build")
    }
    func testSkippedVersionIsNamedAsSkipped() {
        XCTAssertEqual(UpdateNotice.line(running: "1.2.0", found: f("1.2.1"), skippedBuild: "1.2.1"), "update available: 1.2.1 (skipped)")
    }
    func testSkippedOtherVersionDoesNotHideANewerOne() {
        XCTAssertEqual(UpdateNotice.line(running: "1.2.0", found: f("1.2.2"), skippedBuild: "1.2.1"), "update available: 1.2.2")
    }
    func testNothingFoundPrintsNothing() {
        XCTAssertNil(UpdateNotice.line(running: "1.2.0", found: nil, skippedBuild: nil))
    }
    func testNumericCompareNotLexical() {
        XCTAssertEqual(UpdateNotice.line(running: "1.9.0", found: f("1.10.0"), skippedBuild: nil), "update available: 1.10.0")
        XCTAssertNil(UpdateNotice.line(running: "1.10.0", found: f("1.9.0"), skippedBuild: nil))
    }
    func testShorterVersionIsPaddedWithZeros() {
        XCTAssertNil(UpdateNotice.line(running: "1.2", found: f("1.2.0"), skippedBuild: nil))
        XCTAssertEqual(UpdateNotice.line(running: "1.2", found: f("1.2.1"), skippedBuild: nil), "update available: 1.2.1")
    }
}
