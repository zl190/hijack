import XCTest

@testable import HijackCore

// W7 (docs/incidents/2026-10-04-echo-missing.md): rebuild the event source before every dictation and on system wake,
// and say on the summary line whether the system saw the talk key go down.
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

    // The probe: 0.3 s after the talk key went out, the system key state shows it down or not.
    func testSummaryHasPostSeenWhenTheSystemShowsTheKeyDown() {
        let r = Rig()
        r.tap.flagsDown = [.maskSecondaryFn]
        r.pressUntilListening(); r.release(); r.clock.advance(2.6)
        let line = r.sink.summaries.last ?? ""
        XCTAssertTrue(line.contains("echo after"), line)
        XCTAssertTrue(line.contains(", post: seen, mic tool"), line)
    }
    func testSessionStateAloneCountsAsSeen() {
        let r = Rig()
        r.tap.sessionFlagsDown = [.maskSecondaryFn]
        r.pressUntilListening(); r.release(); r.clock.advance(2.6)
        XCTAssertTrue(r.sink.summaries.last?.contains(", post: seen, mic tool") == true, r.sink.summaries.last ?? "")
        XCTAssertTrue(r.sink.traces.contains("post sample hid=off session=on"), "\(r.sink.traces)")
    }
    func testHidStateAloneCountsAsSeenAndIsTraced() {
        let r = Rig()
        r.tap.flagsDown = [.maskSecondaryFn]
        r.pressUntilListening(); r.release(); r.clock.advance(2.6)
        XCTAssertTrue(r.sink.traces.contains("post sample hid=on session=off"), "\(r.sink.traces)")
    }
    func testSummaryHasPostNotSeenWhenTheKeyStateIsUp() {
        let r = Rig()
        r.pressUntilListening(); r.release(); r.clock.advance(2.6)
        let line = r.sink.summaries.last ?? ""
        XCTAssertTrue(line.contains(", post: not seen, mic tool"), line)
        XCTAssertTrue(r.sink.traces.contains("post sample hid=off session=off"), "\(r.sink.traces)")
    }
    // A released-before-sample dictation never got the reading: `?`, not a guess.
    func testSummaryHasPostUnknownWhenReleasedBeforeTheSample() {
        let r = Rig()
        r.press(); r.clock.advance(0.25); r.release(); r.clock.advance(2.6)
        let line = r.sink.summaries.last ?? ""
        XCTAssertTrue(line.contains("post: ?"), line)
    }
    // A key that is not a modifier is read back through keyState.
    func testNonModifierTalkKeyIsReadThroughKeyState() {
        let r = Rig()
        r.plan.forwardKey = KeySpec(code: 49); r.engine.refresh()
        XCTAssertFalse(r.plan.forwardKey.modifierOnly, "setup: a plain key")
        r.tap.keysDown = [r.plan.forwardKey.code]
        r.pressUntilListening(echo: false); r.release(); r.clock.advance(2.6)
        XCTAssertTrue(r.sink.summaries.last?.contains("post: seen") == true, r.sink.summaries.last ?? "")
    }
}
