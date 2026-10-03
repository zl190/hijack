import XCTest
@testable import HijackCore

// FI-1: the event tap goes away or lies (docs/fmea.md FM-01, 02, 04, 24, 25, 26).
final class FI1TapTests: XCTestCase {

    // FM-01: the tap is disabled while the shortcut is held; the release never arrives.
    func testFM01_MissedReleaseAfterTapTimeoutReleasesTheTalkKey() {
        let r = Rig()
        r.pressUntilListening()
        XCTAssertEqual(r.keys.count(Rig.fn, down: true), 1)
        r.tap.keysDown = []                                  // the keyboard has Fn up; we still have it down
        XCTAssertTrue(r.engine.handle(KeyInput(kind: .tapDisabledByTimeout)))
        r.clock.advance(0)                                   // reconcile runs on the next turn
        XCTAssertTrue(r.sink.has("catching up"))
        XCTAssertEqual(r.keys.count(Rig.fn, down: false), 1, "the talk key is released once")
        XCTAssertEqual(r.engine.machine.state, .waitingForText)
        XCTAssertFalse(r.engine.physicalDown)
    }

    // FM-01, the quiet case: the keyboard still has Fn down, so nothing changes.
    func testFM01_TapTimeoutWhileStillHeldChangesNothing() {
        let r = Rig()
        r.pressUntilListening()
        r.tap.keysDown = [63]
        _ = r.engine.handle(KeyInput(kind: .tapDisabledByTimeout))
        r.clock.advance(0)
        XCTAssertFalse(r.sink.has("catching up"))
        XCTAssertEqual(r.engine.machine.state, .listening)
        XCTAssertEqual(r.keys.count(Rig.fn, down: false), 0)
    }

    // FM-02: the re-enable does not take; one retry on the next turn, state.json shows both.
    func testFM02_FailedReenableIsRetriedAndReported() {
        let r = Rig()
        r.tap.enabled = false; r.tap.enableFails = 1
        _ = r.engine.handle(KeyInput(kind: .tapDisabledByTimeout))
        XCTAssertFalse(r.tap.isEnabled)
        XCTAssertTrue(r.sink.has("re-enable failed, retrying"))
        XCTAssertEqual(r.sink.states.last.map { [$0.trusted, $0.tapActive] }, [true, false])
        r.clock.advance(0)
        XCTAssertTrue(r.tap.isEnabled)
        XCTAssertTrue(r.sink.has("re-enabled on retry"))
        XCTAssertEqual(r.sink.states.last.map { [$0.trusted, $0.tapActive] }, [true, true])
    }

    // FM-02, the normal case: re-enabled at once, one log line, no state change.
    func testFM02_ReenableThatTakesLogsOnce() {
        let r = Rig()
        let states = r.sink.states.count
        r.tap.enabled = false
        _ = r.engine.handle(KeyInput(kind: .tapDisabledByUserInput))
        XCTAssertTrue(r.sink.has("disabled by the system (user input), re-enabled"))
        XCTAssertEqual(r.sink.states.count, states)
    }

    // FM-04: a release whose press the tap never saw is not ours; it passes to the system.
    func testFM04_ReleaseWithoutPressPasses() {
        let r = Rig()
        XCTAssertTrue(r.release())
        XCTAssertEqual(r.engine.machine.state, .idle)
        XCTAssertEqual(r.keys.posted.count, 0)
    }

    // FM-04: reconcile picks up a press the tap missed, so the release that follows is ours.
    func testFM04_ReconcileAdoptsAMissedPress() {
        let r = Rig()
        r.tap.keysDown = [63]
        r.engine.reconcile()
        XCTAssertTrue(r.engine.physicalDown)
        XCTAssertTrue(r.sink.has("trigger is down but we had it up"))
        XCTAssertFalse(r.release(), "the release is swallowed: the press was ours")
    }

    // FM-25: the Mac slept while the talk key was held. On wake the session stops in hold mode.
    func testFM25_WakeDuringHoldStopsTheSession() {
        let r = Rig()
        r.pressUntilListening()
        r.engine.reconcileAfterWake(.systemWake)
        XCTAssertTrue(r.sink.has("session was active across system wake"))
        XCTAssertEqual(r.keys.count(Rig.fn, down: false), 1)
        XCTAssertEqual(r.engine.machine.state, .waitingForText)
    }

    // FM-25: the same in toggle mode, where the key is up by design and a press stops the session.
    func testFM25_WakeDuringToggleStopsTheSession() {
        let r = Rig(toggle: true)
        r.press(); r.release(); r.clock.advance(0.3)
        XCTAssertEqual(r.engine.machine.state, .listening)
        r.engine.reconcileAfterWake(.screenUnlock)
        XCTAssertEqual(r.keys.count(Rig.fn, down: false), 1)
        XCTAssertEqual(r.engine.machine.state, .waitingForText)
    }

    // FM-25: wake during starting, before the talk key went out: the session stops, no release is posted.
    func testFM25_WakeDuringStartingStopsWithoutARelease() {
        let r = Rig()
        r.press(); r.clock.advance(0.1)
        XCTAssertEqual(r.engine.machine.state, .starting)
        r.engine.reconcileAfterWake(.systemWake)
        XCTAssertEqual(r.engine.machine.state, .waitingForText)
        XCTAssertEqual(r.keys.posted.count, 0)
    }

    // FM-25 (review-4 S3): the wake notification arrives after the user already started a new dictation. Leave it.
    func testFM25_LateWakeNotificationLeavesAFreshDictationAlone() {
        let r = Rig()
        r.engine.systemWillSleep()
        r.clock.advance(60)
        r.pressUntilListening()
        r.engine.reconcileAfterWake(.systemWake)
        XCTAssertEqual(r.engine.machine.state, .listening, "pressed after the sleep: not ours to stop")
        XCTAssertEqual(r.keys.count(Rig.fn, down: false), 0)
    }

    // FM-25 (review-4 S3): the session started before the sleep. The wake stops it.
    func testFM25_SessionFromBeforeTheSleepIsStopped() {
        let r = Rig()
        r.pressUntilListening()
        r.engine.systemWillSleep()
        r.clock.advance(60)
        r.engine.reconcileAfterWake(.systemWake)
        XCTAssertEqual(r.engine.machine.state, .waitingForText)
        XCTAssertEqual(r.keys.count(Rig.fn, down: false), 1)
    }

    // FM-25 (review-4 S3): the same two branches for the screen lock.
    func testFM25_UnlockUsesTheLockTime() {
        let r = Rig(toggle: true)
        r.engine.screenLocked()
        r.clock.advance(5)
        r.press(); r.release(); r.clock.advance(0.3)
        r.engine.reconcileAfterWake(.screenUnlock)
        XCTAssertEqual(r.engine.machine.state, .listening, "started after the lock")
        r.engine.screenLocked()
        r.clock.advance(5)
        r.engine.reconcileAfterWake(.screenUnlock)
        XCTAssertEqual(r.engine.machine.state, .waitingForText, "started before this lock")
    }

    // FM-25: wake while idle changes nothing.
    func testFM25_WakeWhileIdleIsQuiet() {
        let r = Rig()
        let lines = r.sink.lines.count
        r.engine.reconcileAfterWake(.systemWake)
        XCTAssertEqual(r.sink.lines.count, lines)
        XCTAssertEqual(r.keys.posted.count, 0)
    }

    // FM-24: Accessibility not granted: state.json says so once, start polls, then installs on the grant.
    func testFM24_StartWaitsForAccessibility() {
        let r = Rig(start: false)
        r.tap.trusted = false
        r.engine.start()
        r.clock.advance(1)
        XCTAssertEqual(r.sink.states.map { [$0.trusted, $0.tapActive] }, [[false, false]], "reported once")
        XCTAssertFalse(r.tap.installed)
        r.tap.trusted = true
        r.clock.advance(1)
        XCTAssertTrue(r.tap.installed)
        XCTAssertEqual(r.sink.states.last.map { [$0.trusted, $0.tapActive] }, [true, true])
        XCTAssertTrue(r.sink.has("started: trigger Fn, forward Fn, voice \(Rig.voice)"))
    }

    // FM-24: the system refuses the tap; start retries every second.
    func testFM24_StartRetriesWhenTheTapIsRefused() {
        let r = Rig(start: false)
        r.tap.installResult = false
        r.engine.start()
        XCTAssertEqual(r.sink.states.last.map { [$0.trusted, $0.tapActive] }, [true, false])
        r.tap.installResult = true
        r.clock.advance(1)
        XCTAssertTrue(r.tap.installed)
    }

    // FM-26: a key that is not the shortcut costs no system call inside the tap.
    func testFM26_OtherKeysCostNoSystemCall() {
        let r = Rig()
        r.probes.calls = 0; r.sources.reads = 0
        for code in [0, 1, 36, 49] { XCTAssertTrue(r.otherKey(code)); XCTAssertTrue(r.otherKey(code, down: false)) }
        XCTAssertEqual(r.probes.calls, 0)
        XCTAssertEqual(r.sources.reads, 0)
        XCTAssertEqual(r.keys.posted.count, 0)
    }
}
