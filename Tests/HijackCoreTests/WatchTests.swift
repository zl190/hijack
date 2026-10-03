import XCTest
@testable import HijackCore

// FM-18 and review-4 S4: the watch covers only folders that exist, and never climbs to a parent.
// The config folder is created at launch (Menu.swift), so it always exists when the watch starts.
// These tests drive the real FSEvents with a temporary folder, so each one takes up to a second.
final class WatchTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hijack-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testFM18_ExistingFolderIsWatchedAndAChangeIsSeen() throws {
        let folder = root.appendingPathComponent("cfg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = folder.appendingPathComponent("config.json")
        let changed = expectation(description: "onChange")
        changed.assertForOverFulfill = false
        let watch = SettingsWatch(paths: [config]) { changed.fulfill() }
        XCTAssertEqual(watch.roots, [folder.path])
        XCTAssertTrue(watch.isWatching)
        try "{}".write(to: config, atomically: true, encoding: .utf8)
        wait(for: [changed], timeout: 3)
        withExtendedLifetime(watch) {}
    }

    func testS4_MissingFolderIsSkippedNotClimbed() {
        let config = root.appendingPathComponent("missing/config.json")
        let watch = SettingsWatch(paths: [config]) { XCTFail("nothing to watch") }
        XCTAssertEqual(watch.roots, [], "no climb to \(root.path)")
        XCTAssertFalse(watch.isWatching)
    }

    func testS4_OnlyTheFoldersThatExistAreWatched() throws {
        let present = root.appendingPathComponent("present")
        try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
        let watch = SettingsWatch(paths: [present.appendingPathComponent("a.json"), root.appendingPathComponent("absent/b.json")]) {}
        XCTAssertEqual(watch.roots, [present.path])
    }

    func testS4_ChangesInASiblingFolderDoNotCount() throws {
        let folder = root.appendingPathComponent("cfg"), other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))   // the folder creations are history before the watch starts
        let changed = expectation(description: "onChange")
        changed.isInverted = true
        let watch = SettingsWatch(paths: [folder.appendingPathComponent("config.json")]) { changed.fulfill() }
        XCTAssertTrue(watch.isWatching)
        try "x".write(to: other.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        wait(for: [changed], timeout: 1)
        withExtendedLifetime(watch) {}
    }
}
