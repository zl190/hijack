import XCTest

@testable import HijackCore

// W7 (docs/incidents/2026-10-04-echo-missing.md): rebuild the event source before every dictation and on system wake,
// (the `post:` probe that came with W7 was dropped on 2026-10-19: ListenerChainTests has what replaced it).
final class EventSourceTests: XCTestCase {

    // After a system wake the source is rebuilt; a screen unlock does not touch it.
    func testSystemWakeRebuildsTheSource() {
        let r = Rig()
        r.engine.reconcileAfterWake(.systemWake)
        XCTAssertEqual(r.keys.rebuilds, ["system wake"])
    }
    func testScreenUnlockDoesNotRebuildTheSource() {
        let r = Rig()
        r.engine.reconcileAfterWake(.screenUnlock)
        XCTAssertEqual(r.keys.rebuilds, [])
    }

    // Staleness flaps inside a degraded run, so every dictation rebuilds once, before its press post.
    func testEveryDictationRebuildsOnceBeforeItsPress() {
        let r = Rig()
        for _ in 0..<3 {
            r.keys.timeline = []
            r.pressUntilListening(); r.release(); r.clock.advance(2.6)
            XCTAssertEqual(r.keys.timeline.first, "rebuild:dictation", "\(r.keys.timeline)")
            XCTAssertEqual(r.keys.timeline.filter { $0.hasPrefix("rebuild") }.count, 1, "\(r.keys.timeline)")
            XCTAssertEqual(r.keys.timeline.firstIndex(of: "post:fn:down"), 1, "the press follows the rebuild: \(r.keys.timeline)")
        }
        XCTAssertEqual(r.keys.rebuilds, ["dictation", "dictation", "dictation"])
    }
    // Out of range: released before the talk key was sent, so no press post and no rebuild.
    func testReleaseBeforeSendDoesNotRebuild() {
        let r = Rig()
        r.press(); r.clock.advance(0.05); r.release(); r.clock.advance(1)
        XCTAssertEqual(r.keys.rebuilds, [])
        XCTAssertEqual(r.keys.count(Rig.fn, down: true), 0)
    }
    // A system wake adds its own marker; the next dictation still rebuilds.
    func testWakeThenDictationRebuildsTwice() {
        let r = Rig()
        r.engine.reconcileAfterWake(.systemWake)
        r.pressUntilListening()
        XCTAssertEqual(r.keys.rebuilds, ["system wake", "dictation"])
    }
}
