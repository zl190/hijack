import XCTest
@testable import HijackCore

// FI-2: the input source switch fails, is slow, or is not needed (docs/fmea.md FM-05, 06, 07, 16).
final class FI2SourcesTests: XCTestCase {

    // FM-05: the source never switches. After maxSwitchWait the talk key stays unsent and the dictation ends.
    func testFM05_NoSwitchMeansNoTalkKey() {
        let r = Rig()
        r.sources.applies = false
        r.press()
        r.clock.advance(1.1)
        XCTAssertEqual(r.keys.posted.count, 0, "no talk key to the wrong input source")
        XCTAssertEqual(r.engine.machine.state, .idle)
        XCTAssertTrue(r.sink.has("input source never switched to \(Rig.voice)"))
        let line = r.sink.summaries.last ?? ""
        XCTAssertTrue(line.contains("input source never switched"), line)
        XCTAssertFalse(line.contains("released before"), line)
        let e = r.lastEntry()
        XCTAssertEqual(e?.outcome, .noWindow)
        XCTAssertEqual(e?.cause, .sourceNotSwitched)
        XCTAssertFalse(r.release(), "the shortcut's release is still ours and is swallowed")
        XCTAssertEqual(r.keys.posted.count, 0)
    }

    // FM-05: the switch fails the first time and takes on the retry; the talk key goes out late, once.
    func testFM05_RetryAfterTheSwitchDidNotStick() {
        let r = Rig()
        r.sources.applies = false
        r.press()
        r.clock.advance(0.05)
        r.sources.applies = true                               // the retry at 0.1 s will take
        r.clock.advance(0.3)
        XCTAssertTrue(r.sink.has("switch to \(Rig.voice) didn't stick, retry ok=true"))
        XCTAssertEqual(r.keys.count(Rig.fn, down: true), 1)
        XCTAssertEqual(r.engine.machine.state, .listening)
    }

    // FM-06: a slow switch under maxSwitchWait only delays the talk key.
    func testFM06_SlowSwitchDelaysTheTalkKey() {
        let r = Rig()
        r.sources.applies = false
        r.press()
        r.clock.advance(0.5)
        XCTAssertEqual(r.keys.posted.count, 0)
        r.sources.currentID = Rig.voice                         // the system caught up
        r.clock.advance(0.1)
        XCTAssertEqual(r.keys.count(Rig.fn, down: true), 1)
        let sent = r.engine.record.keySentMs ?? -1
        XCTAssertTrue((500...620).contains(sent), "sent after \(sent)ms")
    }

    // FM-07: the dictation starts inside the voice IME. There is nothing to switch back to.
    func testFM07_StartedInsideTheVoiceIMEDoesNotSwitchBack() {
        let r = Rig(trigger: KeySpec.named("right_option")!, current: Rig.voice)
        r.pressUntilListening(); r.release()
        r.probes.window = .none("no window (pid 100)")
        r.clock.advance(2.6)
        XCTAssertEqual(r.engine.machine.state, .idle)
        XCTAssertEqual(r.sources.selected, [], "no switch at all")
        XCTAssertTrue(r.sink.summaries.last?.contains("started inside WeType, nothing to switch back to") == true)
        XCTAssertEqual(r.lastEntry()?.outcome, .noWindow)
    }

    // FM-07: a previous dictation's source must not leak into the next one.
    func testFM07_PreviousResetsPerDictation() {
        let r = Rig(trigger: KeySpec.named("right_option")!)
        r.pressUntilListening(); r.release(); r.clock.advance(2.8)   // past the restore and its 0.1 s confirm
        XCTAssertEqual(r.sources.selected, [Rig.voice, Rig.english], "the first dictation switches there and back")
        XCTAssertEqual(r.sources.currentID, Rig.english)
        r.sources.currentID = Rig.voice                         // the user picked WeType by hand
        r.pressUntilListening(); r.release(); r.clock.advance(2.8)
        XCTAssertEqual(r.sources.selected, [Rig.voice, Rig.english], "the second dictation selects nothing")
        XCTAssertEqual(r.sources.currentID, Rig.voice, "the user's choice stands")
    }

    // FM-16: the switch back is refused. The log names the step; the user is left in the voice IME.
    func testFM16_RestoreThatIsRefusedIsLogged() {
        let r = Rig()
        r.sources.refuse = [Rig.english]
        r.pressUntilListening(); r.release(); r.clock.advance(2.7)
        XCTAssertEqual(r.sources.currentID, Rig.voice)
        XCTAssertTrue(r.sink.has("restore \(Rig.english) didn't stick, retry ok=false"))
        XCTAssertTrue(r.sink.summaries.last?.contains("back after 2.5") == true, r.sink.summaries.last ?? "")
    }

    // FM-05 control: an app tool (no input source) sends the talk key after holdDelay, whatever the source.
    func testFM05_AppToolIgnoresTheInputSource() {
        let r = Rig(switchesInput: false, trigger: KeySpec.named("right_option")!)
        r.sources.applies = false
        r.press(); r.clock.advance(0.25)
        XCTAssertEqual(r.keys.count(Rig.fn, down: true), 1)
        XCTAssertEqual(r.sources.selected, [])
    }
}

// FM-17 (review-4 M1): a press while the previous dictation waits for its text. The chain must end where it began.
extension FI2SourcesTests {
    func testFM17_ChainedDictationRestoresTheOriginalSource() {
        let r = Rig(trigger: KeySpec.named("right_option")!)
        r.pressUntilListening(); r.release()
        r.clock.advance(0.5)                                    // still waiting for the text
        XCTAssertEqual(r.engine.machine.state, .waitingForText)
        r.pressUntilListening(); r.release()
        r.clock.advance(2.8)
        XCTAssertEqual(r.engine.machine.state, .idle)
        XCTAssertEqual(r.sources.currentID, Rig.english, "back where the user was before the first press")
        XCTAssertEqual(r.sources.selected, [Rig.voice, Rig.english])
        XCTAssertTrue(r.sink.summaries.first?.contains("interrupted by the next press") == true)
        XCTAssertTrue(r.sink.summaries.last?.contains("back after") == true, r.sink.summaries.last ?? "")
    }
}

// FM-05 (review-4 S1): the switch lands after switchFailed. The user must not stay in the voice IME.
extension FI2SourcesTests {
    func testFM05_LateSwitchAfterFailureIsRestored() {
        let r = Rig()
        r.sources.applies = false
        r.press(); r.clock.advance(1.1)
        XCTAssertEqual(r.engine.machine.state, .idle)
        r.sources.applies = true
        r.sources.currentID = Rig.voice                         // TIS caught up at 1.2 s
        r.clock.advance(0.5)
        XCTAssertEqual(r.sources.currentID, Rig.english, "restored to where the user was")
        XCTAssertTrue(r.sink.has("restore after failed switch"))
    }

    func testFM05_NoLateSwitchMeansNoRestore() {
        let r = Rig()
        r.sources.applies = false
        r.press(); r.clock.advance(1.1)
        let selects = r.sources.selected.count
        r.clock.advance(1.0)
        XCTAssertEqual(r.sources.selected.count, selects, "nothing to undo")
        XCTAssertFalse(r.sink.has("restore after failed switch"))
    }
}

// Review-4 N1: a holdDelay above maxSwitchWait must not read as a failed switch.
extension FI2SourcesTests {
    func testN1_LongHoldDelayWithTheSourceReadySendsTheTalkKey() {
        let r = Rig()
        r.plan.holdDelay = 1.5
        r.engine.refresh()
        r.press(); r.clock.advance(1.45)
        XCTAssertEqual(r.keys.posted.count, 0)
        XCTAssertEqual(r.engine.machine.state, .starting)
        r.clock.advance(0.1)
        XCTAssertEqual(r.keys.count(Rig.fn, down: true), 1)
        XCTAssertEqual(r.engine.machine.state, .listening)
        XCTAssertFalse(r.sink.has("input source never switched"))
    }

    func testN1_LongHoldDelayWithNoSwitchStillFailsAtMaxSwitchWait() {
        let r = Rig()
        r.plan.holdDelay = 1.5
        r.engine.refresh()
        r.sources.applies = false
        r.press(); r.clock.advance(1.05)
        XCTAssertEqual(r.engine.machine.state, .idle)
        XCTAssertEqual(r.keys.posted.count, 0)
        XCTAssertTrue(r.sink.has("input source never switched"))
    }
}
