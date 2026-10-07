import XCTest

@testable import HijackCore

// W9 (docs/incidents/2026-10-04-echo-missing.md): every dictation line says whether the system had App Nap engaged.
final class AppNapTests: XCTestCase {
    private func line(_ r: Rig, hold: Double = 0.6) -> String {
        r.pressUntilListening(hold: hold); r.release(); r.clock.advance(2.6)
        return r.sink.summaries.last ?? ""
    }

    func testNappedShowsNapOnAndTheRole() {
        let r = Rig(); r.probes.process = ProcessState(napped: true, role: 7)
        let l = line(r)
        XCTAssertTrue(l.contains(", nap: on, role: 7, mic tool"), l)
    }
    func testNotNappedShowsNapOff() {
        let r = Rig(); r.probes.process = ProcessState(napped: false, role: 1)
        let l = line(r)
        XCTAssertTrue(l.contains(", nap: off, role: 1, mic tool"), l)
        XCTAssertFalse(l.contains("nap: on"), l)
    }
    func testUnreadableShowsNapQuestionMarkAndNoRole() {
        let r = Rig()
        let l = line(r)
        XCTAssertTrue(l.contains(", nap: ?, mic tool"), l)
        XCTAssertFalse(l.contains("role:"), l)
    }
    // Out of range: no held sample means `nap: ?` even when the process is napped.
    func testTapStyleHasNoSample() {
        let r = Rig(start: false); r.plan.style = "tap"; r.engine.start()
        r.probes.process = ProcessState(napped: true, role: 7)
        let l = line(r)
        XCTAssertTrue(l.contains("nap: ?"), l)
        XCTAssertFalse(l.contains("nap: on"), l)
    }
    func testReleaseBeforeTheSampleHasNoSample() {
        let r = Rig(); r.probes.process = ProcessState(napped: true, role: 7)
        r.press(); r.clock.advance(0.3); r.release(); r.clock.advance(2.6)  // key sent at 0.22 s, sample due at 0.52 s
        let l = r.sink.summaries.last ?? ""
        XCTAssertTrue(l.contains("sent after"), "setup: the key went out: \(l)")
        XCTAssertTrue(l.contains("nap: ?"), l)
    }
    // The sample comes from the probe, not from the post-seen read.
    func testNapIsIndependentOfPostSeen() {
        let r = Rig(); r.probes.process = ProcessState(napped: true, role: 7)
        r.tap.flagsDown = [.maskSecondaryFn]  // post: seen
        let l = line(r)
        XCTAssertTrue(l.contains("post: seen, nap: on"), l)
        let r2 = Rig(); r2.probes.process = ProcessState(napped: false, role: 7)  // post not seen
        let l2 = line(r2)
        XCTAssertTrue(l2.contains("post: not seen, nap: off"), l2)
    }

    func testStartedAndRelaunchLinesCarryNapFromAReadAtThatMoment() {
        let r = Rig(start: false); r.probes.process = ProcessState(napped: true, role: 7)
        r.engine.start()
        XCTAssertTrue(r.sink.lines.contains { $0.hasPrefix("started: ") && $0.hasSuffix(" nap=on") }, "\(r.sink.lines)")
        let r2 = Rig(start: false); r2.probes.process = ProcessState(napped: false, role: 7)
        r2.engine.start()
        XCTAssertTrue(r2.sink.lines.contains { $0.hasPrefix("started: ") && $0.hasSuffix(" nap=off") }, "\(r2.sink.lines)")
        let r3 = Rig()  // unreadable
        XCTAssertTrue(r3.sink.lines.contains { $0.hasPrefix("started: ") && $0.hasSuffix(" nap=?") }, "\(r3.sink.lines)")
        // the relaunch line reads at relaunch time: napped during the failing dictation's end, not set before
        let r4 = Rig(); r4.probes.process = ProcessState(napped: true, role: 7)
        r4.pressUntilListening(hold: 0.6, echo: false); r4.release(); r4.clock.advance(2.6)
        XCTAssertTrue(r4.sink.lines.contains { $0.hasPrefix("self-relaunch: ") && $0.hasSuffix(" nap=on") }, "\(r4.sink.lines)")
    }

    func testStatsCountsNappedSampledAndFailed() {
        let ts =
            "2026-10-07 12:00:00.000 dictation x (hold): held 1.00s, fn sent after 200ms, window closed 100ms after release, back after 1.0s"
        let on = " | echo after 5ms, post: seen, nap: on, role: 7, mic tool on device on"
        let onMissing = " | echo missing, post: not seen, nap: on, role: 7, mic tool off device off"
        let off = " | echo after 5ms, post: seen, nap: off, role: 1, mic tool on device on"
        let lines = [
            ts + on, ts + onMissing, ts + onMissing, ts + off, ts + off, ts + " | echo after 5ms, post: seen, mic tool on device on",
        ]
        let s = DictationStats.compute(lines: lines, today: "2026-10-07")
        XCTAssertEqual(s.napped, 3)
        XCTAssertEqual(s.nappedSampled, 5)
        XCTAssertEqual(s.nappedFailed, 2)
        // `nap: ?` and old lines are not sampled.
        let none = DictationStats.compute(lines: [ts + " | echo after 5ms, post: seen, nap: ?, mic tool on device on"], today: "2026-10-07")
        XCTAssertEqual(none.nappedSampled, 0)
        XCTAssertEqual(none.napped, 0)
        XCTAssertEqual(none.nappedFailed, 0)
    }
}
