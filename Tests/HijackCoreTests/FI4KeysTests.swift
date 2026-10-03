import XCTest
@testable import HijackCore

// FI-4: the talk key does not go out, or stays out (docs/fmea.md FM-08, 09, 10).
final class FI4KeysTests: XCTestCase {

    // FM-08: the system refuses to create the press event. The line says so; the release is still posted.
    func testFM08_FailedPressIsLoggedAndTheReleaseStillGoesOut() {
        let r = Rig()
        r.keys.failNext = 1
        r.pressUntilListening(echo: false)
        XCTAssertTrue(r.sink.has("couldn't create the Fn press event"))
        XCTAssertEqual(r.keys.count(Rig.fn, down: true), 0)
        r.release(); r.clock.advance(2.6)
        XCTAssertEqual(r.keys.count(Rig.fn, down: false), 1)
        XCTAssertTrue(r.sink.summaries.last?.contains("echo missing") == true)
        XCTAssertEqual(r.lastEntry()?.cause, .keyNotSent)
    }

    // FM-09: the key was posted but never came back through the tap.
    func testFM09_NoEchoIsOnTheLine() {
        let r = Rig()
        r.pressUntilListening(echo: false); r.release(); r.clock.advance(2.6)
        XCTAssertTrue(r.sink.summaries.last?.contains("echo missing") == true)
        XCTAssertEqual(r.lastEntry()?.cause, .keyNotSent)
    }

    // FM-09 control: the echo arrives and its time is on the line; its release edge is not counted.
    func testFM09_EchoIsTimedOnce() {
        let r = Rig()
        r.press(); r.clock.advance(0.25)
        r.echo()
        r.clock.advance(0.4)
        r.release(); r.clock.advance(2.6)
        let line = r.sink.summaries.last ?? ""
        XCTAssertTrue(line.contains("echo after 250ms"), line)
        XCTAssertEqual(r.lastEntry()?.cause, .windowNotSeen)
    }

    // FM-10: the previous process died with the talk key down. A new engine releases it 1 s after the tap starts.
    func testFM10_StuckModifierIsReleasedOneSecondAfterStart() {
        let r = Rig(start: false)
        r.tap.flagsDown = [.maskSecondaryFn]
        r.engine.start()
        r.clock.advance(0.9)
        XCTAssertEqual(r.keys.posted.count, 0, "not yet: the user may be holding the key")
        r.clock.advance(0.1)
        XCTAssertEqual(r.keys.posted.map { [$0.key.code, $0.down ? 1 : 0] }, [[63, 0]], "one release, nothing else")
        XCTAssertTrue(r.sink.has("cleared a stuck Fn"))
    }

    // FM-10 (review-4 S2): the user holds Fn at launch and lets go. An edge of the key came through: not stuck.
    func testFM10_KeyHeldByTheUserAtLaunchIsNotReleased() {
        let r = Rig(start: false)
        r.tap.flagsDown = [.maskSecondaryFn]
        r.engine.start()
        r.clock.advance(0.4)
        r.release()                                            // the user lets go of Fn (an edge through the tap)
        r.tap.flagsDown = []
        r.clock.advance(0.6)
        XCTAssertEqual(r.keys.posted.count, 0)
        XCTAssertFalse(r.sink.has("cleared a stuck"))
    }

    // FM-10 (review-4 S2): the user keeps holding Fn past the second. The check cannot tell; it releases. Known limit.
    func testFM10_KeyHeldLongerThanOneSecondIsTakenAsStuck() {
        let r = Rig(start: false)
        r.tap.flagsDown = [.maskSecondaryFn]
        r.engine.start()
        r.clock.advance(1.0)
        XCTAssertEqual(r.keys.count(Rig.fn, down: false), 1)
    }

    // FM-10: a key that is not down at start is left alone.
    func testFM10_NothingStuckPostsNothing() {
        let r = Rig(); r.clock.advance(1.0)
        XCTAssertEqual(r.keys.posted.count, 0)
        XCTAssertFalse(r.sink.has("cleared a stuck"))
    }

    // FM-10: a non-modifier forward key is checked through the key state.
    func testFM10_StuckPlainKeyIsReleasedAtStart() {
        let r = Rig(start: false)
        r.plan.forwardKey = KeySpec.named("f13")!
        r.tap.keysDown = [105]
        r.engine.start(); r.clock.advance(1.0)
        XCTAssertEqual(r.keys.posted.map { [$0.key.code, $0.down ? 1 : 0] }, [[105, 0]])
        XCTAssertTrue(r.sink.has("cleared a stuck F13"))
    }
}
