import Foundation
import XCTest
@testable import HijackCore

// One test per acceptance line in docs/state-machine.md, then the generated state diagram.
final class SessionMachineTests: XCTestCase {
    let hold = SessionMode(toggle: false, switchesInput: true, passthrough: false)
    let holdApp = SessionMode(toggle: false, switchesInput: false, passthrough: false)
    let toggle = SessionMode(toggle: true, switchesInput: true, passthrough: false)
    let toggleApp = SessionMode(toggle: true, switchesInput: false, passthrough: false)
    let own = SessionMode(toggle: false, switchesInput: true, passthrough: true)

    func t(_ s: SessionState, _ e: SessionEvent, _ m: SessionMode) -> (SessionState, [SessionEffect]) {
        SessionMachine.transition(s, e, m)
    }

    // 1
    func testPressPassesThroughToTheToolsOwnKey() {
        XCTAssertEqual(t(.idle, .press, own).0, .passthrough)
        XCTAssertEqual(t(.idle, .press, own).1, [.passKey])
    }
    // 2
    func testPressStartsADictation() {
        XCTAssertEqual(t(.idle, .press, hold).0, .starting)
        XCTAssertEqual(t(.idle, .press, hold).1, [.swallowKey, .begin, .switchToVoice, .scheduleTalkKey])
        XCTAssertEqual(t(.idle, .press, holdApp).1, [.swallowKey, .begin, .scheduleTalkKey])
        XCTAssertEqual(t(.idle, .press, SessionMode(toggle: true, switchesInput: true, passthrough: true)).0, .starting,
                       "toggle never passes through")
    }
    // 3
    func testTalkKeyIsSentOnlyWhileStarting() {
        XCTAssertEqual(t(.starting, .keySent, hold).0, .listening)
        XCTAssertEqual(t(.starting, .keySent, hold).1, [.sendTalkKey])
        for s in SessionState.allCases where s != .starting {
            XCTAssertEqual(t(s, .keySent, hold).0, s, "\(s)")
            XCTAssertEqual(t(s, .keySent, hold).1, [], "\(s)")
        }
    }
    // 4
    func testHoldReleaseStops() {
        XCTAssertEqual(t(.listening, .release, hold).0, .waitingForText)
        XCTAssertEqual(t(.listening, .release, hold).1, [.swallowKey, .releaseTalkKey, .waitForText])
        XCTAssertEqual(t(.starting, .release, hold).1, [.swallowKey, .waitForText], "never sent, so nothing to release")
        XCTAssertEqual(t(.listening, .release, holdApp).0, .idle)
        XCTAssertEqual(t(.listening, .release, holdApp).1, [.swallowKey, .releaseTalkKey, .finish])
    }
    // 5
    func testToggleReleaseKeepsGoingAndSecondPressStops() {
        XCTAssertEqual(t(.listening, .release, toggle).0, .listening)
        XCTAssertEqual(t(.listening, .release, toggle).1, [.swallowKey])
        XCTAssertEqual(t(.listening, .press, toggle).0, .waitingForText)
        XCTAssertEqual(t(.listening, .press, toggle).1, [.swallowKey, .releaseTalkKey, .waitForText])
        XCTAssertEqual(t(.listening, .press, toggleApp).0, .idle)
    }
    // 6
    func testToggleAnyKeyStopsAndIsSwallowed() {
        XCTAssertEqual(t(.listening, .otherKey, toggle).0, .waitingForText)
        XCTAssertEqual(t(.listening, .otherKey, toggle).1.first, .swallowKeyAndItsRelease)
        XCTAssertEqual(t(.listening, .otherKey, hold).1, [.passKey], "hold mode never sees otherKey from the engine, but stays safe")
    }
    // 7
    func testTextDoneFinishesOnlyWhileWaiting() {
        XCTAssertEqual(t(.waitingForText, .textDone, hold).0, .idle)
        XCTAssertEqual(t(.waitingForText, .textDone, hold).1, [.finish])
        for s in SessionState.allCases where s != .waitingForText {
            XCTAssertEqual(t(s, .textDone, hold).1, [], "\(s)")
        }
    }
    // 8
    func testPressWhileWaitingFinishesThePreviousFirst() {
        XCTAssertEqual(t(.waitingForText, .press, hold).0, .starting)
        XCTAssertEqual(t(.waitingForText, .press, hold).1.first, .finishPrevious)
        XCTAssertEqual(t(.waitingForText, .press, own).1, [.finishPrevious, .passKey])
    }
    // 9
    func testPassthroughReleaseReturnsToIdle() {
        XCTAssertEqual(t(.passthrough, .release, own).0, .idle)
        XCTAssertEqual(t(.passthrough, .release, own).1, [.passKey])
    }
    // 10 and invariants over every (state, event, mode)
    func testEveryCombinationIsDefinedAndConsistent() {
        let modes = [hold, holdApp, toggle, toggleApp, own]
        for s in SessionState.allCases { for e in SessionEvent.allCases { for m in modes {
            let (next, fx) = t(s, e, m)
            let keyEvent = e == .press || e == .release || e == .otherKey
            let keyFx = fx.filter { [.passKey, .swallowKey, .swallowKeyAndItsRelease].contains($0) }
            XCTAssertEqual(keyFx.count, keyEvent ? 1 : 0, "\(s) \(e) \(m): a key event gets exactly one pass/swallow")
            if fx.contains(.sendTalkKey) { XCTAssertEqual(next, .listening) }
            if fx.contains(.releaseTalkKey) { XCTAssertEqual(s, .listening, "only a sent key is released") }
            if fx.contains(.waitForText) { XCTAssertTrue(m.switchesInput) }
            if next == .waitingForText && s != .waitingForText { XCTAssertTrue(fx.contains(.waitForText)) }
        }}}
    }
    // A sequence, the way the engine drives it: hold, speak, release, text arrives.
    func testHoldDictationEndToEnd() {
        var machine = SessionMachine()
        var all: [SessionEffect] = []
        for e: SessionEvent in [.press, .keySent, .release, .textDone] { all += machine.handle(e, hold) }
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(all, [.swallowKey, .begin, .switchToVoice, .scheduleTalkKey, .sendTalkKey,
                             .swallowKey, .releaseTalkKey, .waitForText, .finish])
    }

    // The state diagram, generated from the transition function. HIJACK_UPDATE_DIAGRAMS=1 rewrites it;
    // otherwise the test fails when the checked-in diagram no longer matches the code.
    // 11
    func testSwitchFailedEndsTheDictationWithoutTheTalkKey() {
        XCTAssertEqual(t(.starting, .switchFailed, hold).0, .idle)
        XCTAssertEqual(t(.starting, .switchFailed, hold).1, [.finish])
        XCTAssertEqual(t(.starting, .switchFailed, toggle).1, [.finish])
        for s in SessionState.allCases where s != .starting {
            XCTAssertEqual(t(s, .switchFailed, hold).0, s, "\(s)")
            XCTAssertEqual(t(s, .switchFailed, hold).1, [], "\(s)")
        }
    }

    func testStateDiagramIsCurrent() throws {
        // Configurations. "Same key": the shortcut is the talk key, so a press passes through whenever the voice
        // input method is already active (decided per press), else it starts a dictation.
        let profiles: [(String, [SessionMode])] = [("按住", [hold]), ("按住·同键", [hold, own]), ("按住·app", [holdApp]),
                                                   ("免按", [toggle]), ("免按·app", [toggleApp])]
        // Per configuration, only the (state, mode) pairs it can reach from idle: what can't happen isn't drawn.
        func reachable(_ modes: [SessionMode]) -> Set<SessionState> {
            var seen: Set<SessionState> = [.idle], todo: [SessionState] = [.idle]
            while let s = todo.popLast() { for e in SessionEvent.allCases { for m in modes {
                let next = t(s, e, m).0
                if seen.insert(next).inserted { todo.append(next) }
            }}}
            return seen
        }
        func valid(_ s: SessionState, _ m: SessionMode) -> Bool { !(m.passthrough && (s == .starting || s == .listening)) }
        var edges: [String: [String]] = [:], order: [String] = []
        for s in SessionState.allCases { for e in SessionEvent.allCases { for (name, modes) in profiles {
            let reach = reachable(modes)
            guard reach.contains(s) else { continue }
            var outcomes: [(SessionState, [SessionEffect])] = []
            for m in modes where valid(s, m) { outcomes.append(t(s, e, m)) }
            for (next, fx) in outcomes {
            guard next != s else { continue }    // staying put (repeats, stale events) is left out of the picture
            let shown = fx.filter { ![.passKey, .swallowKey].contains($0) }.map { "\($0)" }
            let key = "\(s.rawValue)|\(next.rawValue)|\(e.rawValue)|\(shown.joined(separator: ", "))"
            if edges[key] == nil { order.append(key) }
            if !edges[key, default: []].contains(name) { edges[key, default: []].append(name) }
            }
        }}}
        var lines = ["stateDiagram-v2", "  [*] --> idle"]
        for key in order {
            let p = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let when = edges[key]!.count == profiles.count ? "" : " [\(edges[key]!.joined(separator: " / "))]"
            let fx = p[3].isEmpty ? "" : "<br/>\(p[3])"
            lines.append("  \(p[0]) --> \(p[1]): \(p[2])\(when)\(fx)")
        }
        let diagram = lines.joined(separator: "\n") + "\n"
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../docs/diagrams/states.mmd").standardized
        if ProcessInfo.processInfo.environment["HIJACK_UPDATE_DIAGRAMS"] == "1" {
            try diagram.write(to: url, atomically: true, encoding: .utf8)
        } else {
            XCTAssertEqual(try? String(contentsOf: url, encoding: .utf8), diagram,
                           "docs/diagrams/states.mmd is out of date: run scripts/diagrams.sh")
        }
    }
}
