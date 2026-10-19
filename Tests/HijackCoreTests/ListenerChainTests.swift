import XCTest

@testable import HijackCore

// W10 (docs/incidents/2026-10-04-echo-missing.md, 2026-10-19 section; docs/adr/0023): another process can keep a
// filtering key listener ahead of ours and swallow the talk key there. Every dictation line says who sits ahead,
// and a relaunch behind such a listener is skipped: the fresh process would be behind it again.
final class ListenerChainTests: XCTestCase {
    private func line(_ r: Rig, echo: Bool = true, hold: Double = 0.6) -> String {
        r.pressUntilListening(hold: hold, echo: echo); r.release(); r.clock.advance(2.6)
        return r.sink.summaries.last ?? ""
    }

    // The field sits where `post:` used to: right after the echo, before `nap:`.
    func testSummarySaysAheadNoneWhenOurListenerIsFirst() {
        let r = Rig()  // FakeTap.ahead defaults to []: nobody ahead
        let l = line(r)
        XCTAssertTrue(l.contains("echo after"), l)
        XCTAssertTrue(l.contains(", ahead: none, nap: ?, mic tool"), l)
        XCTAssertFalse(l.contains("post:"), l)
    }
    func testSummaryNamesTheListenersAheadInChainOrder() {
        let r = Rig(); r.tap.ahead = ["WeType", "LinearMouse"]
        let l = line(r, echo: false)
        XCTAssertTrue(l.contains("echo missing, ahead: WeType+LinearMouse, nap: ?, mic tool"), l)
    }
    func testSummarySaysAheadUnknownWhenTheChainCouldNotBeRead() {
        let r = Rig(); r.tap.ahead = nil
        let l = line(r)
        XCTAssertTrue(l.contains(", ahead: ?, nap: ?, mic tool"), l)
    }
    // Out of range: no sample, no reading. `?`, not a guess.
    func testReleaseBeforeTheSampleLeavesAheadUnknown() {
        let r = Rig(); r.tap.ahead = ["WeType"]
        r.press(); r.clock.advance(0.25); r.release(); r.clock.advance(2.6)
        let l = r.sink.summaries.last ?? ""
        XCTAssertTrue(l.contains("sent after"), "setup: the key went out: \(l)")
        XCTAssertTrue(l.contains("ahead: ?"), l)
        XCTAssertEqual(r.tap.aheadReads, 0)
    }
    func testTapStyleHasNoSample() {
        let r = Rig(start: false); r.plan.style = "tap"; r.engine.start(); r.tap.ahead = ["WeType"]
        XCTAssertTrue(line(r).contains("ahead: ?"), r.sink.summaries.last ?? "")
    }
    // One read per dictation, at the 0.3 s sample; the half-second samples after it do not read again.
    func testChainIsReadOncePerDictation() {
        let r = Rig()
        _ = line(r, hold: 1.5)
        XCTAssertEqual(r.tap.aheadReads, 1)
        _ = line(r, hold: 0.6)
        XCTAssertEqual(r.tap.aheadReads, 2)
    }

    // W8's relaunch (ADR 0022) is for a fault inside this process. Behind another listener it is skipped.
    func testFailedPostBehindAnotherListenerDoesNotRelaunchAndSaysWhy() {
        let r = Rig(); r.tap.ahead = ["WeType"]
        _ = line(r, echo: false)
        XCTAssertEqual(r.supervisor.relaunches, [])
        XCTAssertNil(r.supervisor.lastRelaunchAt)
        XCTAssertTrue(
            r.sink.lines.contains(
                "self-relaunch skipped: WeType's key listener sits ahead of ours (talk key did not go out: echo missing)"),
            "\(r.sink.lines)")
    }
    func testFailedPostWithOurListenerFirstRelaunches() {
        let r = Rig()
        _ = line(r, echo: false)
        XCTAssertEqual(r.supervisor.relaunches, ["talk key did not go out: echo missing"])
    }
    // An unreadable chain cannot block the one remedy that is left.
    func testFailedPostWithUnknownChainRelaunches() {
        let r = Rig(); r.tap.ahead = nil
        _ = line(r, echo: false)
        XCTAssertEqual(r.supervisor.relaunches.count, 1)
        XCTAssertFalse(r.sink.has("self-relaunch skipped"), "\(r.sink.lines)")
    }
    func testEchoSeenBehindAnotherListenerNeitherRelaunchesNorSkips() {
        let r = Rig(); r.tap.ahead = ["WeType"]
        _ = line(r, echo: true)
        XCTAssertEqual(r.supervisor.relaunches, [])
        XCTAssertFalse(r.sink.has("self-relaunch"), "\(r.sink.lines)")
    }

    // Stats: who was ahead, how often, and how many of those failed. Lines from before the field are not sampled.
    func testStatsCountsListenersAhead() {
        let ts =
            "2026-10-19 12:00:00.000 dictation x (hold): held 1.00s, fn sent after 200ms, window never closed after release, back after 2.5s"
        let ahead = " | echo missing, ahead: WeType, nap: off, role: 2, mic tool off device off"
        let aheadOK = " | echo after 5ms, ahead: WeType+LinearMouse, nap: off, role: 2, mic tool on device on"
        let none = " | echo after 5ms, ahead: none, nap: off, role: 2, mic tool on device on"
        let unknown = " | echo after 5ms, ahead: ?, nap: ?, mic tool on device on"
        let old = " | echo missing, post: not seen, nap: off, role: 2, mic tool off device off"
        let s = DictationStats.compute(lines: [ts + ahead, ts + aheadOK, ts + none, ts + unknown, ts + old], today: "2026-10-19")
        XCTAssertEqual(s.aheadSampled, 3)
        XCTAssertEqual(s.listenerAhead, 2)
        XCTAssertEqual(s.listenerAheadFailed, 1)
        let e = DictationEntry.parse(ts + aheadOK)!
        XCTAssertEqual(e.listenersAhead, ["WeType", "LinearMouse"])
        XCTAssertEqual(DictationEntry.parse(ts + none)!.listenersAhead, [])
        XCTAssertNil(DictationEntry.parse(ts + unknown)!.listenersAhead)
        XCTAssertNil(DictationEntry.parse(ts + old)!.listenersAhead)
    }
    // The pre-W10 `post:` field still parses and still feeds the "key never went out" cause.
    func testOldPostFieldStillParses() {
        let old =
            "2026-10-06 18:00:00.000 dictation x (hold): held 2.00s, fn sent after 210ms, window never closed after release, back after 2.5s | echo missing, post: not seen, mic tool off device off | front=x"
        let e = DictationEntry.parse(old)!
        XCTAssertEqual(e.postSeen, false)
        XCTAssertEqual(e.cause, .keyNotSent)
    }
}
