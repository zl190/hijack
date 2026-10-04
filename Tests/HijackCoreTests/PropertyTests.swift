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

    /// Tracks the history an invariant needs across a run: nothing here is in `SessionMachine` itself,
    /// which is why these are properties of the *trace*, not of a single `transition` call.
    struct History {
        var releasedSinceLastSend = false  // line 4 / line 12: a release with no sendTalkKey after it
        var awaitingCloseSinceLastSend = false  // lines 2, 4, 7, 11, 12: a send not yet closed by release/finish
    }

    /// Runs one `Run` to completion, failing with the seed, mode and sequence on the first broken invariant.
    func check(_ run: Run) {
        var machine = SessionMachine()
        var history = History()
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

            // Line 12: quit from starting or listening goes to idle; elsewhere it changes nothing (tested
            // directly in SessionMachineTests). The property test covers only the first half, over every
            // state the random walk actually reaches.
            if event == .quit, before == .starting || before == .listening {
                guard after == .idle else { fail(12, "after quit from \(before), the state must be idle", at: step, event: event); return }
            }

            // Lines 4 and 12: a sent talk key is released at most once before it is sent again.
            // releaseTalkKey never appears twice with no sendTalkKey between the two appearances.
            if effects.contains(.releaseTalkKey) {
                guard !history.releasedSinceLastSend else {
                    fail(4, "releaseTalkKey appeared twice with no sendTalkKey between", at: step, event: event); return
                }
                history.releasedSinceLastSend = true
            }
            if effects.contains(.sendTalkKey) { history.releasedSinceLastSend = false }

            // Lines 2, 4, 7, 11, 12: every sendTalkKey is closed (releaseTalkKey or finish) before the next begin.
            if effects.contains(.begin) {
                guard !history.awaitingCloseSinceLastSend else {
                    fail(2, "begin arrived before the previous sendTalkKey was closed by releaseTalkKey or finish", at: step, event: event)
                    return
                }
            }
            if effects.contains(.sendTalkKey) { history.awaitingCloseSinceLastSend = true }
            if effects.contains(.releaseTalkKey) || effects.contains(.finish) { history.awaitingCloseSinceLastSend = false }

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
