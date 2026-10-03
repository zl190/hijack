import XCTest
@testable import HijackCore

// FM-18: the config folder does not exist at launch. The watch must still see the file when it appears.
// These tests drive the real FSEvents with a temporary folder, so each one takes about a second.
final class WatchTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hijack-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testFM18_FolderCreatedAfterTheWatchStartsIsSeen() throws {
        let config = root.appendingPathComponent("cfg/config.json")
        let changed = expectation(description: "onChange")
        changed.assertForOverFulfill = false
        let watch = SettingsWatch(paths: [config]) { changed.fulfill() }
        XCTAssertEqual(watch.roots, [SettingsWatch.resolve(root.path)], "watches the nearest folder that exists")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: config, atomically: true, encoding: .utf8)
        wait(for: [changed], timeout: 3)
        withExtendedLifetime(watch) {}
    }

    func testFM18_ChangesOutsideTheWatchedFoldersDoNotCount() throws {
        let config = root.appendingPathComponent("cfg/config.json")
        let changed = expectation(description: "onChange")
        changed.isInverted = true
        let watch = SettingsWatch(paths: [config]) { changed.fulfill() }
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "x".write(to: other.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        wait(for: [changed], timeout: 1)
        withExtendedLifetime(watch) {}
    }

    func testFM18_ExistingFolderIsWatchedDirectly() throws {
        let folder = root.appendingPathComponent("cfg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = folder.appendingPathComponent("config.json")
        let changed = expectation(description: "onChange")
        changed.assertForOverFulfill = false
        let watch = SettingsWatch(paths: [config]) { changed.fulfill() }
        XCTAssertEqual(watch.roots, [SettingsWatch.resolve(folder.path)])
        try "{}".write(to: config, atomically: true, encoding: .utf8)
        wait(for: [changed], timeout: 3)
        withExtendedLifetime(watch) {}
    }

    func testResolveKeepsTheMissingTail() {
        let r = SettingsWatch.resolve("/var/folders/does-not-exist/cfg")
        XCTAssertTrue(r.hasPrefix("/private/var/folders/"), r)
        XCTAssertTrue(r.hasSuffix("/does-not-exist/cfg"), r)
    }
}
