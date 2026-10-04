import XCTest

@testable import HijackCore

// Real summary lines from ~/Library/Logs/Hijack.log (2026-10-03), plus failure lines in the same format
// Engine.summary writes (none of those happened on this machine yet).
final class StatsTests: XCTestCase {
    let ok1 =
        "2026-10-03 19:22:11.636 dictation WeType (hold): held 3.0s, Fn sent after 238ms, window closed 1627ms after release, back after 1.82s | echo after 245ms, mic tool on device on, window while held: 1 window | front=com.anthropic.claudefordesktop"
    let ok2 =
        "2026-10-03 20:14:56.536 dictation WeType (toggle): held 9.09s, Fn sent after 239ms, window closed 1602ms after release, back after 1.76s | echo after 239ms, mic tool on device on, window while held: 1 window | front=com.anthropic.claudefordesktop"
    let tap =
        "2026-10-03 20:14:32.139 dictation WeType (hold): held 0.09s, released before Fn was sent | front=com.anthropic.claudefordesktop"
    let micOff =
        "2026-10-03 21:00:00.000 dictation WeType (hold): held 2.00s, Fn sent after 210ms, window never closed after release, back after 2.50s | echo after 212ms, mic tool off device on, window while held: no window (pid 912), key tap disabled | front=x"
    let noEcho =
        "2026-10-03 21:01:00.000 dictation WeType (hold): held 2.00s, Fn sent after 210ms, window never closed after release, back after 2.50s | echo missing, mic tool off device off, window while held: no window (pid 912) | front=x"
    let unseen =
        "2026-10-03 21:02:00.000 dictation WeType (hold): held 2.00s, Fn sent after 210ms, window never closed after release, back after 2.50s | echo after 211ms, mic tool on device on, window while held: no window (pid 912) | front=x"
    let cut =
        "2026-10-03 21:03:00.000 dictation WeType (hold): held 1.00s, Fn sent after 205ms, window never closed after release, interrupted by the next press | echo after 206ms, mic tool on device on, window while held: 1 window | front=x"
    let noSwitch = "2026-10-03 21:05:00.000 dictation WeType (hold): held 1.20s, input source never switched | front=x"
    let app =
        "2026-10-03 21:04:00.000 dictation Handy (hold): held 1.50s, Option sent after 200ms, no switch back needed | echo after 201ms, mic tool on device on | front=x"

    func testParsesASuccess() {
        let e = DictationEntry.parse(ok1)!
        XCTAssertEqual(e.tool, "WeType"); XCTAssertEqual(e.heldMs, 3000); XCTAssertEqual(e.sentMs, 238)
        XCTAssertEqual(e.textInMs, 1627); XCTAssertEqual(e.outcome, .textArrived); XCTAssertNil(e.cause)
        XCTAssertTrue(DictationEntry.parse(ok2)!.toggle)
    }
    func testClassifiesFailuresByTheirChecks() {
        XCTAssertEqual(DictationEntry.parse(micOff)!.cause, .toolDidntListen)
        XCTAssertTrue(DictationEntry.parse(micOff)!.tapDisabled)
        XCTAssertEqual(DictationEntry.parse(noEcho)!.cause, .keyNotSent)
        XCTAssertEqual(DictationEntry.parse(unseen)!.cause, .windowNotSeen)
        XCTAssertEqual(DictationEntry.parse(cut)!.outcome, .interrupted)
        XCTAssertEqual(DictationEntry.parse(app)!.outcome, .unverified)
        XCTAssertEqual(DictationEntry.parse(tap)!.outcome, .tooShort)
    }
    func testIgnoresOtherLines() {
        XCTAssertNil(DictationEntry.parse("2026-10-03 20:12:34.975 started: trigger Right Option, forward Fn"))
        XCTAssertNil(DictationEntry.parse("10-03 16:26:59.776 check: echo seen, mic off"))  // the older format
        XCTAssertNil(DictationEntry.parse(""))
    }

    // review-5 #17: Engine.summary now writes the provider id and the key's logID (stable, not localized).
    // The parser makes no assumption about which form `tool` is in: an id line (new) and a display-name
    // line (old, ok1 above) parse the same way, each keeping whatever string was actually on the line.
    func testParsesTheNewIdBasedFormatTheSameAsTheOldNameBasedOne() {
        let idLine =
            "2026-10-03 22:00:00.000 dictation com.tencent.inputmethod.wetype.pinyin (hold): held 3.0s, fn sent after 238ms, window closed 1627ms after release, back after 1.82s | echo after 245ms, mic tool on device on, window while held: 1 window | front=com.anthropic.claudefordesktop"
        let e = DictationEntry.parse(idLine)!
        XCTAssertEqual(e.tool, "com.tencent.inputmethod.wetype.pinyin")
        XCTAssertEqual(e.outcome, .textArrived)
        XCTAssertEqual(e.sentMs, 238)
        XCTAssertEqual(DictationEntry.parse(ok1)!.tool, "WeType", "the old line keeps its own (display-name) tool string")
    }
    func testStats() {
        let lines = [
            ok1, ok2, tap, micOff, noEcho, unseen, cut, app,
            "2026-10-03 21:05:00.000 event tap was disabled by the system (timeout), re-enabled",
            "2026-10-03 21:05:01.000 slow key event (another key): 283ms old on arrival, handled in 0ms",
            "2026-09-01 10:00:00.000 " + String(ok1.dropFirst(24)),
        ]  // an old success, outside 7 days
        let s = DictationStats.compute(lines: lines, days: 7, today: "2026-10-03")
        XCTAssertEqual(s.dictations, 7)
        XCTAssertEqual(s.tooShort, 1)
        XCTAssertEqual(s.outcomes[.textArrived], 2)
        XCTAssertEqual(s.outcomes[.noWindow], 3)
        XCTAssertEqual(s.successRate!, 2.0 / 5.0, accuracy: 1e-9)
        XCTAssertEqual(s.causes, [.toolDidntListen: 1, .keyNotSent: 1, .windowNotSeen: 1])
        XCTAssertEqual(s.tapPaused, 1); XCTAssertEqual(s.slowKeys, 1)
        XCTAssertEqual(s.tools, ["WeType": 6, "Handy": 1])
        XCTAssertEqual(DictationStats.compute(lines: lines, days: nil, today: "2026-10-03").dictations, 8)
    }
    func testPercentiles() {
        let lines = (1...20).map {
            "2026-10-03 10:00:\(String(format: "%02d", $0)).000 dictation WeType (hold): held 1.00s, Fn sent after \($0 * 10)ms, window closed 1000ms after release, back after 1.2s | echo after 1ms"
        }
        let s = DictationStats.compute(lines: lines, today: "2026-10-03")
        XCTAssertEqual(s.sentP50, 100); XCTAssertEqual(s.sentP95, 190)
    }

    func testSwitchFailureIsAFailureWithItsOwnCause() {
        let e = DictationEntry.parse(noSwitch)
        XCTAssertEqual(e?.outcome, .noWindow)
        XCTAssertEqual(e?.cause, .sourceNotSwitched)
        XCTAssertNil(e?.sentMs)
    }
}
