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
    // W11 (docs/adr/0024): follow mode. The trigger is the tool's own talk key; the tool switches itself in.
    let follow = SessionMode(toggle: false, switchesInput: true, passthrough: false, follow: true)
    let followOwn = SessionMode(toggle: false, switchesInput: true, passthrough: true, follow: true)  // already in the voice source
    let followApp = SessionMode(toggle: false, switchesInput: false, passthrough: false, follow: true)
    var allModes: [SessionMode] { [hold, holdApp, toggle, toggleApp, own, follow, followOwn, followApp] }

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
        XCTAssertEqual(
            t(.idle, .press, SessionMode(toggle: true, switchesInput: true, passthrough: true)).0, .starting,
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
        let modes = allModes
        for s in SessionState.allCases {
            for e in SessionEvent.allCases {
                for m in modes {
                    let (next, fx) = t(s, e, m)
                    let keyEvent = e == .press || e == .release || e == .otherKey
                    let keyFx = fx.filter { [.passKey, .swallowKey, .swallowKeyAndItsRelease].contains($0) }
                    XCTAssertEqual(keyFx.count, keyEvent ? 1 : 0, "\(s) \(e) \(m): a key event gets exactly one pass/swallow")
                    if fx.contains(.sendTalkKey) { XCTAssertEqual(next, .listening) }
                    if fx.contains(.releaseTalkKey) { XCTAssertEqual(s, .listening, "only a sent key is released") }
                    if fx.contains(.waitForText) { XCTAssertTrue(m.switchesInput) }
                    if next == .waitingForText && s != .waitingForText {
                        XCTAssertTrue(fx.contains(.waitForText) || fx.contains(.watchTool))
                    }
                    // W11: following is entered only by a follow-mode press; the tool's own switch-in goes straight to the watch.
                    if fx.contains(.rememberSource) {
                        XCTAssertTrue(m.follow && !m.toggle, "\(s) \(e) \(m)")
                        XCTAssertEqual(next, e == .toolStarted ? .waitingForText : .following, "\(s) \(e) \(m)")
                        if e == .press { XCTAssertFalse(m.passthrough, "\(s) \(e) \(m)") }
                        XCTAssertFalse(
                            fx.contains(.switchToVoice) || fx.contains(.scheduleTalkKey) || fx.contains(.sendTalkKey), "\(s) \(e) \(m)")
                    }
                    if next == .following && s != .following {
                        XCTAssertTrue(fx.contains(.rememberSource) && fx.contains(.begin), "\(s) \(e) \(m)")
                    }
                    if fx.contains(.watchTool) { XCTAssertTrue(m.switchesInput, "\(s) \(e) \(m)") }
                    if e == .toolStarted && fx.contains(.watchTool) { XCTAssertTrue(m.follow && !m.toggle, "\(s) \(m)") }
                    if e == .toolStarted && !(m.follow && !m.toggle && m.switchesInput) {
                        XCTAssertEqual(fx, [], "\(s) \(m)"); XCTAssertEqual(next, s)
                    }
                    // Follow never posts: a press can only lead to following or passthrough, never to starting (where the key is sent).
                    if m.follow && !m.toggle && e == .press && (s == .idle || s == .waitingForText) {
                        XCTAssertTrue(next == .following || next == .passthrough, "follow never starts a posted dictation: \(s) \(m)")
                    }
                }
            }
        }
    }
    // A sequence, the way the engine drives it: hold, speak, release, text arrives.
    func testHoldDictationEndToEnd() {
        var machine = SessionMachine()
        var all: [SessionEffect] = []
        for e: SessionEvent in [.press, .keySent, .release, .textDone] { all += machine.handle(e, hold) }
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(
            all,
            [
                .swallowKey, .begin, .switchToVoice, .scheduleTalkKey, .sendTalkKey,
                .swallowKey, .releaseTalkKey, .waitForText, .finish,
            ])
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
    // 12
    func testQuitStopsImmediatelyWithoutWaitingForText() {
        XCTAssertEqual(t(.listening, .quit, hold).0, .idle)
        XCTAssertEqual(t(.listening, .quit, hold).1, [.releaseTalkKey], "release the sent key, no waitForText")
        XCTAssertEqual(t(.starting, .quit, hold).0, .idle)
        XCTAssertEqual(t(.starting, .quit, hold).1, [], "never sent, so nothing to release")
        // S1 (docs/review-4/hardening-review.md): acceptance line 12's "elsewhere quit changes nothing" had
        // a behavior test for idle only. Loop the rest, as test 11 does for switchFailed — idle,
        // waitingForText and passthrough, across every mode: quit's catch-all ignores mode entirely.
        for s in SessionState.allCases where s != .starting && s != .listening {
            for m in allModes {
                XCTAssertEqual(t(s, .quit, m).0, s, "\(s) \(m)")
                XCTAssertEqual(t(s, .quit, m).1, [], "\(s) \(m)")
            }
        }
    }

    // 13 (W11): a follow-mode press outside the voice source passes the key, opens a record, remembers the source.
    func testFollowPressPassesTheKeyAndRemembersTheSource() {
        XCTAssertEqual(t(.idle, .press, follow).0, .following)
        XCTAssertEqual(t(.idle, .press, follow).1, [.passKey, .begin, .rememberSource])
        XCTAssertEqual(t(.waitingForText, .press, follow).0, .following)
        XCTAssertEqual(t(.waitingForText, .press, follow).1, [.finishPrevious, .passKey, .begin, .rememberSource])
        XCTAssertEqual(t(.following, .press, follow).0, .following, "a repeat while held")
        XCTAssertEqual(t(.following, .press, follow).1, [.passKey])
        // Out of range: toggle wins over follow (never follows), and a plain hold press never follows.
        XCTAssertEqual(t(.idle, .press, SessionMode(toggle: true, switchesInput: true, passthrough: false, follow: true)).0, .starting)
        XCTAssertEqual(t(.idle, .press, hold).0, .starting)
        XCTAssertFalse(t(.idle, .press, hold).1.contains(.rememberSource))
    }
    // 14 (W11): the release passes the key and waits for the text; an app has nothing to switch back.
    func testFollowReleaseWaitsForTheTextThenFinishes() {
        XCTAssertEqual(t(.following, .release, follow).0, .waitingForText)
        XCTAssertEqual(
            t(.following, .release, follow).1, [.passKey, .watchTool], "the tool's own signals end it, not the key path's window-only watch"
        )
        XCTAssertEqual(t(.following, .release, followApp).0, .idle)
        XCTAssertEqual(t(.following, .release, followApp).1, [.passKey, .finish])
        XCTAssertEqual(t(.waitingForText, .textDone, follow).0, .idle)
        XCTAssertEqual(t(.waitingForText, .textDone, follow).1, [.finish])
        // Out of range: nothing posted, so nothing to release or to send; stale events change nothing.
        for e: SessionEvent in [.keySent, .textDone, .switchFailed, .quit, .toolStarted] {
            XCTAssertEqual(t(.following, e, follow).0, .following, "\(e)")
            XCTAssertEqual(t(.following, e, follow).1, [], "\(e)")
        }
        XCTAssertEqual(t(.following, .otherKey, follow).1, [.passKey])
        // Out of range: following is never released into by another mode's machinery.
        for m in [hold, holdApp, toggle, toggleApp, own] {
            XCTAssertNotEqual(t(.idle, .press, m).0, .following, "\(m)")
        }
    }
    // 15 (W11): already in the voice source (and no restore pending): plain passthrough, as 1.
    func testFollowInsideTheVoiceSourceIsPlainPassthrough() {
        XCTAssertEqual(t(.idle, .press, followOwn).0, .passthrough)
        XCTAssertEqual(t(.idle, .press, followOwn).1, [.passKey])
        XCTAssertEqual(t(.passthrough, .release, followOwn).0, .idle)
        XCTAssertEqual(t(.passthrough, .release, followOwn).1, [.passKey])
        XCTAssertEqual(t(.waitingForText, .press, followOwn).1, [.finishPrevious, .passKey])
    }
    // 16 (W11): the tool switched itself in. Idle: a dictation with no key seen. Waiting for a key-path dictation's
    // text: that one is written up and the watch restarts on the tool's signals. Anywhere else, and outside follow
    // mode for an input method: nothing.
    func testToolSwitchInStartsADictationOnlyInFollowModeFromIdleOrWaiting() {
        XCTAssertEqual(t(.idle, .toolStarted, follow).0, .waitingForText)
        XCTAssertEqual(t(.idle, .toolStarted, follow).1, [.begin, .rememberSource, .watchTool])
        XCTAssertEqual(t(.waitingForText, .toolStarted, follow).0, .waitingForText)
        XCTAssertEqual(t(.waitingForText, .toolStarted, follow).1, [.finishPrevious, .begin, .rememberSource, .watchTool])
        XCTAssertEqual(
            t(.idle, .toolStarted, followOwn).1, [.begin, .rememberSource, .watchTool], "passthrough is about a key; there is none")
        // Out of range: an app (nothing to switch), the other modes, and the states where a key or a post is in flight.
        XCTAssertEqual(t(.idle, .toolStarted, followApp).1, [])
        for m in [hold, holdApp, toggle, toggleApp, own, SessionMode(toggle: true, switchesInput: true, passthrough: false, follow: true)] {
            XCTAssertEqual(t(.idle, .toolStarted, m).0, .idle, "\(m)")
            XCTAssertEqual(t(.idle, .toolStarted, m).1, [], "\(m)")
            XCTAssertEqual(t(.waitingForText, .toolStarted, m).1, [], "\(m)")
        }
        for s: SessionState in [.following, .passthrough, .starting, .listening] {
            XCTAssertEqual(t(s, .toolStarted, follow).0, s, "\(s)")
            XCTAssertEqual(t(s, .toolStarted, follow).1, [], "\(s)")
        }
    }
    func testFollowDictationEndToEnd() {
        var machine = SessionMachine()
        var all: [SessionEffect] = []
        for e: SessionEvent in [.press, .release, .textDone] { all += machine.handle(e, follow) }
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(all, [.passKey, .begin, .rememberSource, .passKey, .watchTool, .finish])
        var tool = SessionMachine()
        var fx: [SessionEffect] = []
        for e: SessionEvent in [.toolStarted, .textDone] { fx += tool.handle(e, follow) }
        XCTAssertEqual(tool.state, .idle)
        XCTAssertEqual(fx, [.begin, .rememberSource, .watchTool, .finish])
        XCTAssertTrue(SessionMachine().passesKeyThrough == false)
        var m2 = SessionMachine(); _ = m2.handle(.press, follow)
        XCTAssertTrue(m2.isActive); XCTAssertTrue(m2.passesKeyThrough)
    }

    func testStateDiagramIsCurrent() throws {
        // Configurations. "Same key": the shortcut is the talk key, so a press passes through whenever the voice
        // input method is already active (decided per press), else it starts a dictation.
        let profiles: [(String, [SessionMode])] = [
            ("按住", [hold]), ("按住·同键", [hold, own]), ("按住·app", [holdApp]),
            ("免按", [toggle]), ("免按·app", [toggleApp]), ("跟随", [follow, followOwn]),
        ]
        // Per configuration, only the (state, mode) pairs it can reach from idle: what can't happen isn't drawn.
        func reachable(_ modes: [SessionMode]) -> Set<SessionState> {
            var seen: Set<SessionState> = [.idle], todo: [SessionState] = [.idle]
            while let s = todo.popLast() {
                for e in SessionEvent.allCases {
                    for m in modes {
                        let next = t(s, e, m).0
                        if seen.insert(next).inserted { todo.append(next) }
                    }
                }
            }
            return seen
        }
        func valid(_ s: SessionState, _ m: SessionMode) -> Bool {
            if m.passthrough && (s == .starting || s == .listening) { return false }
            if s == .following && !m.follow { return false }
            return true
        }
        var edges: [String: [String]] = [:], order: [String] = []
        // How many configurations can be in each state: an edge every one of them shares is drawn unqualified.
        var reachers: [SessionState: Int] = [:]
        for (_, modes) in profiles { for s in reachable(modes) { reachers[s, default: 0] += 1 } }
        for s in SessionState.allCases {
            for e in SessionEvent.allCases {
                for (name, modes) in profiles {
                    let reach = reachable(modes)
                    guard reach.contains(s) else { continue }
                    var outcomes: [(SessionState, [SessionEffect])] = []
                    for m in modes where valid(s, m) { outcomes.append(t(s, e, m)) }
                    for (next, fx) in outcomes {
                        guard next != s else { continue }  // staying put (repeats, stale events) is left out of the picture
                        let shown = fx.filter { ![.passKey, .swallowKey].contains($0) }.map { "\($0)" }
                        let key = "\(s.rawValue)|\(next.rawValue)|\(e.rawValue)|\(shown.joined(separator: ", "))"
                        if edges[key] == nil { order.append(key) }
                        if !edges[key, default: []].contains(name) { edges[key, default: []].append(name) }
                    }
                }
            }
        }
        var lines = ["stateDiagram-v2", "  [*] --> idle"]
        for key in order {
            let p = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let when = edges[key]!.count == reachers[SessionState(rawValue: p[0])!] ? "" : " [\(edges[key]!.joined(separator: " / "))]"
            let fx = p[3].isEmpty ? "" : "<br/>\(p[3])"
            lines.append("  \(p[0]) --> \(p[1]): \(p[2])\(when)\(fx)")
        }
        let diagram = lines.joined(separator: "\n") + "\n"
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../docs/diagrams/states.mmd").standardized
        if ProcessInfo.processInfo.environment["HIJACK_UPDATE_DIAGRAMS"] == "1" {
            try diagram.write(to: url, atomically: true, encoding: .utf8)
        } else {
            XCTAssertEqual(
                try? String(contentsOf: url, encoding: .utf8), diagram,
                "docs/diagrams/states.mmd is out of date: run scripts/diagrams.sh")
        }
    }
}
