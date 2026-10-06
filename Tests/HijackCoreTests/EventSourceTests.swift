import XCTest

@testable import HijackCore

// W7 (docs/incidents/2026-10-04-echo-missing.md): rebuild the event source after sleep and after a long idle,
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

    /// One dictation, then `gap` seconds of nothing, then the next press. Returns the rig after the second press went out.
    private func secondPress(after gap: Double) -> Rig {
        let r = Rig()
        r.pressUntilListening(); r.release(); r.clock.advance(2.6)
        XCTAssertEqual(r.keys.rebuilds, [], "setup: nothing rebuilt yet")
        r.clock.advance(gap)
        r.pressUntilListening(hold: 0.3)
        return r
    }

    // The gap counts from the last post (the release, about 2 s into the first dictation).
    func testPressAfterElevenMinutesRebuildsBeforeThePost() {
        let r = secondPress(after: 11 * 60)
        XCTAssertEqual(r.keys.rebuilds.count, 1)
        XCTAssertTrue(r.keys.rebuilds.first?.hasPrefix("idle ") == true, "\(r.keys.rebuilds)")
        XCTAssertEqual(r.keys.count(Rig.fn, down: true), 2, "the second press still went out")
    }
    func testPressAfterOneMinuteDoesNotRebuild() {
        XCTAssertEqual(secondPress(after: 60).keys.rebuilds, [])
    }
    // The boundary is "more than 10 minutes". The test sets lastPostAt itself, so the gap is exact.
    func testExactlyTenMinutesDoesNotRebuild() {
        let r = Rig()
        r.pressUntilListening(); r.release()
        r.engine.lastPostAt = r.clock.now
        r.clock.advance(Engine.idleRebuildAfter)
        r.engine.post(Rig.fn, down: true)
        XCTAssertEqual(r.keys.rebuilds, [])
    }
    func testTenMinutesAndASecondRebuilds() {
        let r = Rig()
        r.pressUntilListening(); r.release()
        r.engine.lastPostAt = r.clock.now
        r.clock.advance(Engine.idleRebuildAfter + 1)
        r.engine.post(Rig.fn, down: true)
        XCTAssertEqual(r.keys.rebuilds, ["idle 10m"])
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
    func testSummaryHasPostNotSeenWhenTheKeyStateIsUp() {
        let r = Rig()
        r.pressUntilListening(); r.release(); r.clock.advance(2.6)
        let line = r.sink.summaries.last ?? ""
        XCTAssertTrue(line.contains(", post: not seen, mic tool"), line)
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
