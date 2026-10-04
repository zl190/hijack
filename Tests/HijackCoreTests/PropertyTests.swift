import XCTest

@testable import HijackCore

// MARK: seeded generator — SplitMix64 (Vigna, "Further scramblings of Marsaglia's xorshift generators",
// 2015), implemented here with no dependency. A fixed seed makes a failing run reproducible: the same
// seed always drives the same sequence, on this machine or any other.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// A value in `0..<bound`.
    mutating func next(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    mutating func bool() -> Bool { next() % 2 == 0 }
}

// MARK: property test — docs/state-machine.md is the contract; each invariant below names the acceptance
// line it comes from. A seeded run drives `SessionMachine.transition` through a random sequence of events
// and random modes, and checks every invariant after every step, over the whole run's history.
final class PropertyTests: XCTestCase {
    static let runs = 10_000
    static let maxEventsPerRun = 30

    /// One run: a fixed mode and a random sequence of up to `maxEventsPerRun` events, from `seed`.
    struct Run {
        var seed: UInt64
        var mode: SessionMode
        var events: [SessionEvent]
    }

    static func makeRun(seed: UInt64) -> Run {
        var rng = SplitMix64(seed: seed)
        let mode = SessionMode(toggle: rng.bool(), switchesInput: rng.bool(), passthrough: rng.bool())
        let count = 1 + rng.next(maxEventsPerRun)  // up to 30 events
        let all = SessionEvent.allCases
        let events = (0..<count).map { _ in all[rng.next(all.count)] }
        return Run(seed: seed, mode: mode, events: events)
    }

    /// Runs one `Run` to completion, failing with the seed, mode and sequence on the first broken invariant.
    ///
    /// review 6, S8: one `talkKeyDown` bool, updated in effect order within each step (not `.contains`,
    /// which would lose the order `stop()` puts `releaseTalkKey` before `finish` in the same step), is the
    /// strongest statement docs/state-machine.md supports: `sendTalkKey` and `releaseTalkKey` strictly
    /// alternate (every exit from `listening` emits `releaseTalkKey` — SessionMachine.swift's own `stop()`),
    /// and the key is up at every `begin` and every `finish`. This subsumes the two weaker trackers it
    /// replaces (a double release with no send between; a send left open across a begin) and also catches
    /// what they missed: a double send with no release between, and a send left open across a *finish*
    /// (not just a begin) — found by review 6 reading `stop()`'s own `mode.toggle && !mode.switchesInput`
    /// branch, which the old, hold-mode-only check at line 4 could not see.
    func check(_ run: Run) {
        var machine = SessionMachine()
        var talkKeyDown = false
        func fail(_ line: Int, _ what: String, at step: Int, event: SessionEvent) {
            XCTFail(
                """
                docs/state-machine.md line \(line): \(what)
                seed \(run.seed), mode \(run.mode), step \(step) (\(event)) of \(run.events.count)
                sequence: \(run.events.map(\.rawValue))
                """)
        }
        for (step, event) in run.events.enumerated() {
            let before = machine.state
            let effects = machine.handle(event, run.mode)
            let after = machine.state

            // Line 12, both halves: quit from starting or listening goes to idle; everywhere else it
            // changes nothing at all (not just "not idle" — the exact prior state, cheaply checked).
            if event == .quit {
                let expected: SessionState = before == .starting || before == .listening ? .idle : before
                guard after == expected else {
                    fail(12, "quit from \(before) must leave the state at \(expected), got \(after)", at: step, event: event); return
                }
            }

            // Lines 2, 4, 7, 11, 12: sendTalkKey and releaseTalkKey strictly alternate, and the key is up
            // (not sent, or already released) at every begin and every finish. Effects are walked in the
            // order `SessionMachine.transition` returns them, because `stop()` can emit releaseTalkKey and
            // finish in the same step, release first — order is the whole point of "closed before finish".
            for effect in effects {
                switch effect {
                case .begin:
                    guard !talkKeyDown else { fail(2, "begin arrived with the talk key still down", at: step, event: event); return }
                case .sendTalkKey:
                    guard !talkKeyDown else {
                        fail(4, "sendTalkKey arrived with the talk key already down", at: step, event: event); return
                    }
                    talkKeyDown = true
                case .releaseTalkKey:
                    guard talkKeyDown else {
                        fail(4, "releaseTalkKey arrived with the talk key already up", at: step, event: event); return
                    }
                    talkKeyDown = false
                case .finish:
                    guard !talkKeyDown else { fail(7, "finish arrived with the talk key still down", at: step, event: event); return }
                default: break
                }
            }

            // Line 4: in hold mode, a release from listening always yields releaseTalkKey.
            if !run.mode.toggle, before == .listening, event == .release {
                guard effects.contains(.releaseTalkKey) else {
                    fail(4, "a hold-mode release from listening must yield releaseTalkKey", at: step, event: event); return
                }
            }
        }
    }

    func testStateMachineInvariantsHoldOver10_000RandomSequences() {
        for seed in 0..<UInt64(Self.runs) {
            check(Self.makeRun(seed: seed))
        }
    }
}
