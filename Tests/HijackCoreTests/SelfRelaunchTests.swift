import XCTest

@testable import HijackCore

// W8 (docs/adr/0022-relaunch-on-a-failed-post.md): relaunch the app after a dictation whose talk key did not go out.
final class SelfRelaunchTests: XCTestCase {
    static let why = "talk key did not go out: echo missing, post not seen"

    /// One dictation that ends with a summary line. `hold` is the time the shortcut stays down (the key goes out at 0.22 s).
    private func dictate(_ r: Rig, hold: Double = 0.6, echo: Bool = false, postSeen: Bool = false) {
        if postSeen { r.tap.flagsDown = [.maskSecondaryFn] }
        r.pressUntilListening(hold: hold, echo: echo); r.release(); r.clock.advance(2.6)
    }

    // The signature: hold style, held >= 0.5 s, key sent, no echo, post not seen.
    func testFailedPostRelaunchesOnceAfterTheSummaryLine() {
        let r = Rig()
        dictate(r)
        XCTAssertEqual(r.supervisor.relaunches, [Self.why])
        let lines = r.sink.lines
        let summary = lines.firstIndex { $0.hasPrefix("dictation ") }
        let relaunch = lines.firstIndex { $0.hasPrefix("self-relaunch: ") }
        XCTAssertNotNil(summary); XCTAssertNotNil(relaunch)
        XCTAssertLessThan(summary ?? 99, relaunch ?? -1, "the summary line comes first: \(lines)")
        XCTAssertEqual(lines[relaunch ?? 0], "self-relaunch: \(Self.why)")
        XCTAssertNotNil(r.supervisor.lastRelaunchAt, "the time is persisted through the supervisor")
    }
    // An unsampled probe (released before the 0.3 s sample could run) counts as not seen.
    func testUnsampledProbeCountsAsNotSeen() {
        let r = Rig()
        r.press(); r.clock.advance(0.51)  // key sent at about 0.22 s; the probe samples 0.3 s later, at about 0.52 s
        XCTAssertEqual(r.engine.machine.state, .listening)
        r.release(); r.clock.advance(2.6)
        let line = r.sink.summaries.last ?? ""
        XCTAssertTrue(line.contains("echo missing, post: ?"), "setup: the probe was not sampled: \(line)")
        XCTAssertEqual(r.supervisor.relaunches.count, 1, line)
    }

    // Out of range, one per condition.
    func testHeldUnderHalfASecondDoesNotRelaunch() {
        let r = Rig()
        r.press(); r.clock.advance(0.4); r.release(); r.clock.advance(2.6)
        XCTAssertTrue(r.sink.summaries.last?.contains("sent after") ?? false, "setup: the key did go out: \(r.sink.summaries)")
        XCTAssertEqual(r.supervisor.relaunches, [])
    }
    func testHeldJustOverHalfASecondRelaunches() {
        let r = Rig()
        r.press(); r.clock.advance(0.55); r.release(); r.clock.advance(2.6)
        XCTAssertEqual(r.supervisor.relaunches.count, 1)
    }
    func testEchoSeenDoesNotRelaunch() {
        let r = Rig()
        dictate(r, echo: true)
        XCTAssertEqual(r.supervisor.relaunches, [])
    }
    func testEchoSeenWithMicOffDoesNotRelaunch() {
        let r = Rig()
        r.probes.micTool = false; r.probes.micDevice = false
        dictate(r, echo: true)
        XCTAssertEqual(r.supervisor.relaunches, [])
    }
    func testPostSeenDoesNotRelaunch() {
        let r = Rig()
        dictate(r, postSeen: true)
        XCTAssertTrue(r.sink.summaries.last?.contains("echo missing, post: seen") ?? false, r.sink.summaries.last ?? "")
        XCTAssertEqual(r.supervisor.relaunches, [])
    }
    func testTapStyleDoesNotRelaunch() {
        let r = Rig(start: false)
        r.plan.style = "tap"
        r.engine.start()
        dictate(r)
        XCTAssertEqual(r.supervisor.relaunches, [])
    }
    func testKeyNeverSentDoesNotRelaunch() {
        let r = Rig(start: false)
        r.plan.holdDelay = 1.0  // the talk key is still waiting for its delay when the shortcut comes up, 0.6 s in
        r.engine.start()
        r.press(); r.clock.advance(0.6); r.release(); r.clock.advance(2.6)
        XCTAssertTrue(r.sink.summaries.last?.contains("held 0.6") ?? false, r.sink.summaries.last ?? "")
        XCTAssertTrue(r.sink.summaries.last?.contains("released before") ?? false, r.sink.summaries.last ?? "")
        XCTAssertEqual(r.supervisor.relaunches, [])
    }

    // Policy: once per 10 minutes, persisted.
    func testSecondFailureNineMinutesLaterIsSuppressed() {
        let r = Rig()
        dictate(r)
        r.clock.advance(9 * 60)
        dictate(r)
        XCTAssertEqual(r.supervisor.relaunches.count, 1)
        XCTAssertEqual(
            r.sink.lines.filter { $0.hasPrefix("self-relaunch suppressed: last one 9m ago (\(Self.why))") }.count, 1, "\(r.sink.lines)")
    }
    func testSecondFailureElevenMinutesLaterRelaunches() {
        let r = Rig()
        dictate(r)
        r.clock.advance(11 * 60)
        dictate(r)
        XCTAssertEqual(r.supervisor.relaunches.count, 2)
        XCTAssertFalse(r.sink.has("suppressed"))
    }
    // A fresh process reads the persisted date: 5 minutes old, so suppressed.
    func testPersistedDateSuppressesInAFreshProcess() {
        let r = Rig(start: false)
        r.supervisor.lastRelaunchAt = r.clock.now.addingTimeInterval(-5 * 60)
        r.engine.start()
        dictate(r)
        XCTAssertEqual(r.supervisor.relaunches, [])
        XCTAssertTrue(r.sink.has("self-relaunch suppressed: last one 5m ago"), "\(r.sink.lines)")
    }
    func testPersistedDateOlderThanTheGapRelaunches() {
        let r = Rig(start: false)
        r.supervisor.lastRelaunchAt = r.clock.now.addingTimeInterval(-11 * 60)
        r.engine.start()
        dictate(r)
        XCTAssertEqual(r.supervisor.relaunches.count, 1)
    }
    // Never while a session is active: a newer press interrupts the summary, the session is live.
    func testNoRelaunchWhileANewerSessionIsActive() {
        let r = Rig()
        r.pressUntilListening(hold: 0.6, echo: false)
        r.release()  // waiting for text
        r.press()  // the next press interrupts: summary(end: interrupted) runs with a new session starting
        XCTAssertTrue(r.sink.summaries.contains { $0.contains("interrupted by the next press") }, "\(r.sink.summaries)")
        XCTAssertEqual(r.supervisor.relaunches, [])
    }

    // The next start says it was a self-relaunch, once.
    func testStartedLineSaysAfterSelfRelaunchOnce() {
        let r = Rig(start: false)
        r.supervisor.mark = true
        r.engine.start()
        XCTAssertTrue(r.sink.lines.contains { $0.hasPrefix("started: ") && $0.hasSuffix(" (after self-relaunch)") }, "\(r.sink.lines)")
        let r2 = Rig(start: false)
        r2.engine.start()
        XCTAssertFalse(r2.sink.has("after self-relaunch"))
    }

    // Stats: only the `self-relaunch:` lines count.
    func testStatsCountsRelaunchesNotSuppressed() {
        let lines = [
            "2026-10-07 12:00:00.000 self-relaunch: \(Self.why)",
            "2026-10-07 12:05:00.000 self-relaunch suppressed: last one 5m ago (\(Self.why))",
            "2026-10-07 12:20:00.000 self-relaunch: \(Self.why)",
            "2026-10-07 12:20:01.000 started: trigger Fn, forward Fn, voice x (after self-relaunch)",
        ]
        XCTAssertEqual(DictationStats.compute(lines: lines, today: "2026-10-07").selfRelaunches, 2)
        XCTAssertEqual(DictationStats.compute(lines: [], today: "2026-10-07").selfRelaunches, 0)
    }
}
