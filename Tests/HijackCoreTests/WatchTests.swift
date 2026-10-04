import XCTest

@testable import HijackCore

// FM-18 and review-4 S4: the watch covers only folders that exist, and never climbs to a parent.
// The config folder is created at launch (Menu.swift), so it always exists when the watch starts.
// SettingsWatch takes its FolderEvents by injection (Sources/Core/Seams.swift): these tests drive a
// FakeFolderEvents by hand, so there is no FSEvents latency and no sleep. testLive_RealFSEventsSeesAWrite
// is the one test left on the real stream, an integration check that FM-18's assumption about FSEvents
// itself still holds; HIJACK_SKIP_LIVE_TESTS=1 skips it.
final class WatchTests: XCTestCase {
    var root: URL!
    var fake: FakeFolderEvents!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hijack-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fake = FakeFolderEvents()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testFM18_ExistingFolderIsWatchedAndAChangeIsSeen() throws {
        let folder = root.appendingPathComponent("cfg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var changed = 0
        let watch = SettingsWatch(paths: [folder.appendingPathComponent("config.json")], events: fake) { changed += 1 }
        XCTAssertEqual(watch.roots, [folder.path])
        XCTAssertTrue(watch.isWatching)
        fake.fire()
        XCTAssertEqual(changed, 1)
    }

    func testS4_MissingFolderIsSkippedNotClimbed() {
        let config = root.appendingPathComponent("missing/config.json")
        let watch = SettingsWatch(paths: [config], events: fake) { XCTFail("nothing to watch") }
        XCTAssertEqual(watch.roots, [], "no climb to \(root.path)")
        XCTAssertFalse(watch.isWatching)
        XCTAssertEqual(fake.startCalls, 1, "start() still runs, with empty roots, like the live stream would")
    }

    func testS4_OnlyTheFoldersThatExistAreWatched() throws {
        let present = root.appendingPathComponent("present")
        try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
        let watch = SettingsWatch(
            paths: [present.appendingPathComponent("a.json"), root.appendingPathComponent("absent/b.json")], events: fake
        ) {}
        XCTAssertEqual(watch.roots, [present.path])
    }

    // review-4 S4: only the folders actually named are ever handed to the stream; a sibling folder
    // that nobody asked to watch must not be among the roots FSEvents is started on.
    func testS4_SiblingFolderIsNeverPassedToTheStream() throws {
        let folder = root.appendingPathComponent("cfg"), other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let watch = SettingsWatch(paths: [folder.appendingPathComponent("config.json")], events: fake) {}
        XCTAssertEqual(fake.startedRoots, [folder.path], "not \(other.path)")
        XCTAssertTrue(watch.isWatching)
    }

    // Integration: the fake above only proves SettingsWatch forwards whatever FolderEvents reports.
    // This test keeps a real FSEventStream, so a change in FSEvents' own behavior still shows up here.
    func testLive_RealFSEventsSeesAWrite() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["HIJACK_SKIP_LIVE_TESTS"] == "1")
        let folder = root.appendingPathComponent("cfg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = folder.appendingPathComponent("config.json")
        let changed = expectation(description: "onChange")
        changed.assertForOverFulfill = false
        let watch = SettingsWatch(paths: [config]) { changed.fulfill() }  // events: defaults to LiveFolderEvents()
        XCTAssertEqual(watch.roots, [folder.path])
        XCTAssertTrue(watch.isWatching)
        try "{}".write(to: config, atomically: true, encoding: .utf8)
        wait(for: [changed], timeout: 3)
        withExtendedLifetime(watch) {}
    }
}
