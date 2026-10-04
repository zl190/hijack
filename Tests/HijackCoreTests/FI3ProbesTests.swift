import XCTest

@testable import HijackCore

// FI-3: the voice tool's window and microphone are not where we expect (docs/fmea.md FM-12, 13, 14, 15).
final class FI3ProbesTests: XCTestCase {

    // FM-15: no window is ever seen. The switch back comes at fallbackDelay, not sooner.
    func testFM15_NoWindowRestoresAtFallbackDelay() {
        let r = Rig()
        r.probes.window = .none("no window (pid 100)")
        r.pressUntilListening(); r.release()
        r.clock.advance(2.45)
        XCTAssertEqual(r.engine.machine.state, .waitingForText, "not before fallbackDelay")
        r.clock.advance(0.1)
        XCTAssertEqual(r.engine.machine.state, .idle)
        XCTAssertTrue((2.5...2.55).contains(r.engine.waited), "waited \(r.engine.waited)")
        let line = r.sink.summaries.last ?? ""
        XCTAssertTrue(line.contains("window never closed after release"), line)
        XCTAssertTrue(line.contains("back after 2.5"), line)
        XCTAssertEqual(r.lastEntry()?.outcome, .noWindow)
        XCTAssertEqual(r.lastEntry()?.cause, .windowNotSeen)
    }

    // FM-14: the window is seen and never closes. The switch back comes at restoreTimeout.
    func testFM14_WindowThatNeverClosesRestoresAtRestoreTimeout() {
        let r = Rig()
        r.probes.window = .visible(1)
        r.pressUntilListening(); r.release()
        r.clock.advance(4.95)
        XCTAssertEqual(r.engine.machine.state, .waitingForText, "not before restoreTimeout")
        r.clock.advance(0.1)
        XCTAssertEqual(r.engine.machine.state, .idle)
        XCTAssertTrue((5.0...5.05).contains(r.engine.waited), "waited \(r.engine.waited)")
        XCTAssertTrue(r.sink.summaries.last?.contains("window never closed after release") == true)
        XCTAssertEqual(r.sources.currentID, Rig.english, "switched back all the same")
    }

    // FM-13: the window closes. The switch back comes capsuleGrace after it went, not at the timeout.
    func testFM13_WindowGoneRestoresAfterTheGrace() {
        let r = Rig()
        r.probes.window = .visible(1)
        r.pressUntilListening(); r.release()
        r.clock.advance(1.0)
        r.probes.window = .none("no window (pid 100)")
        r.clock.advance(0.1)
        XCTAssertEqual(r.engine.machine.state, .waitingForText, "inside the grace")
        r.clock.advance(0.15)
        XCTAssertEqual(r.engine.machine.state, .idle)
        let gone = r.engine.record.windowGoneMs ?? -1
        XCTAssertTrue((1000...1060).contains(gone), "window gone after \(gone)ms")
        XCTAssertTrue((1.15...1.25).contains(r.engine.waited), "waited \(r.engine.waited)")
        XCTAssertEqual(r.lastEntry()?.outcome, .textArrived)
        XCTAssertEqual(r.lastEntry()?.textInMs, gone)
    }

    // FM-15: the voice tool is not running. The window probe says so on the line; the wait is fallbackDelay.
    func testFM15_ToolNotRunningIsNamedOnTheLine() {
        let r = Rig()
        r.probes.pids = []
        r.pressUntilListening(); r.release(); r.clock.advance(2.6)
        let line = r.sink.summaries.last ?? ""
        XCTAssertTrue(line.contains("window while held: not running"), line)
        XCTAssertTrue(line.contains("back after 2.5"), line)
    }

    // FM-12: the microphone probe cannot tell. The line says "?" and Stats does not blame the tool.
    func testFM12_UnknownMicIsAQuestionMark() {
        let r = Rig()
        r.probes.micTool = nil; r.probes.micDevice = nil
        r.pressUntilListening(); r.release(); r.clock.advance(2.6)
        let line = r.sink.summaries.last ?? ""
        XCTAssertTrue(line.contains("mic tool ? device ?"), line)
        XCTAssertEqual(r.lastEntry()?.cause, .unknown)
    }

    // FM-12: the microphone is off while the key is held: the tool did not listen.
    func testFM12_MicOffBlamesTheTool() {
        let r = Rig()
        r.probes.micTool = false
        r.pressUntilListening(); r.release(); r.clock.advance(2.6)
        XCTAssertTrue(r.sink.summaries.last?.contains("mic tool off device on") == true)
        XCTAssertEqual(r.lastEntry()?.cause, .toolDidntListen)
    }

    // FM-13 control: the sample while held carries the window the tool had at the time.
    func testFM13_SampleWhileHeldRecordsTheWindow() {
        let r = Rig()
        r.probes.window = .visible(2)
        r.pressUntilListening()
        r.clock.advance(0.35)
        XCTAssertEqual(r.engine.record.heldWindow, .visible(2))
        r.release(); r.clock.advance(5.1)
        XCTAssertTrue(r.sink.summaries.last?.contains("window while held: 2 windows") == true)
    }
}
