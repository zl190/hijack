import CoreGraphics
import Foundation
import XCTest

@testable import HijackCore

// Fakes for the six seams (Sources/Core/Seams.swift). Each one records what Engine asked for and can fail on demand.

final class FakeClock: Scheduler {
    var now = Date(timeIntervalSince1970: 1_000_000)
    private var queue: [(at: Date, seq: Int, work: () -> Void)] = []
    private var seq = 0
    func after(_ seconds: Double, _ work: @escaping () -> Void) { seq += 1; queue.append((now.addingTimeInterval(seconds), seq, work)) }
    // Inline by default: deterministic, and every existing test relies on that. A test that needs to
    // reproduce a real hop-off-and-back race (review-4 S1) sets deferOffMain and flushes by hand, so it
    // can run other engine calls (like a release) in between the dispatch and the completion.
    var deferOffMain = false
    private var heldOffMain: [() -> Void] = []
    func offMain<T>(_ work: @escaping () -> T, then done: @escaping (T) -> Void) {
        let result = work()
        if deferOffMain { heldOffMain.append { done(result) } } else { done(result) }
    }
    func flushOffMain() { let held = heldOffMain; heldOffMain = []; for f in held { f() } }
    /// Move time forward. Due work runs in order, at its own time.
    func advance(_ seconds: Double) {
        let target = now.addingTimeInterval(seconds)
        while let next = queue.filter({ $0.at <= target }).min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) {
            queue.removeAll { $0.seq == next.seq }
            now = max(now, next.at)
            next.work()
        }
        now = target
    }
    var pending: Int { queue.count }
}

final class FakeKeys: KeyPoster {
    var posted: [(key: KeySpec, down: Bool)] = []
    var failNext = 0  // the next N posts return false (FM-08)
    var rebuilds: [String] = []  // the reason of each rebuild(reason:) call (W7)
    var timeline: [String] = []  // "rebuild:<reason>" and "post:<key id>:down|up" in call order
    func rebuild(reason: String) { rebuilds.append(reason); timeline.append("rebuild:\(reason)") }
    @discardableResult func post(_ key: KeySpec, down: Bool) -> Bool {
        timeline.append("post:\(key.logID):\(down ? "down" : "up")")
        if failNext > 0 { failNext -= 1; return false }
        posted.append((key, down)); return true
    }
    func count(_ key: KeySpec, down: Bool) -> Int { posted.filter { $0.key == key && $0.down == down }.count }
}

final class FakeSources: InputSources {
    var currentID: String?
    var applies = true  // select changes currentID
    var refuse: Set<String> = []  // select returns false for these (FM-16)
    var selected: [String] = []
    var reads = 0
    init(_ current: String?) { currentID = current }
    func current() -> String? { reads += 1; return currentID }
    func select(_ id: String) -> Bool {
        selected.append(id)
        if refuse.contains(id) { return false }
        if applies { currentID = id }
        return true
    }
}

final class FakeTap: TapControl {
    var trusted = true
    var installResult = true
    var installed = false
    var enabled = false
    var enableFails = 0  // the next N enables do nothing (FM-02)
    var keysDown: Set<Int> = []
    var flagsDown: CGEventFlags = []
    var sessionKeysDown: Set<Int> = []  // the combined session state (W7 probe reads both)
    var sessionFlagsDown: CGEventFlags = []
    var secureInputOn = false
    var onEvent: ((KeyInput) -> Bool)?
    func install(_ onEvent: @escaping (KeyInput) -> Bool) -> Bool {
        guard installResult else { return false }
        self.onEvent = onEvent; installed = true; return true
    }
    var isEnabled: Bool { enabled }
    func enable() { if enableFails > 0 { enableFails -= 1 } else { enabled = true } }
    func keyIsDown(_ code: Int) -> Bool { keysDown.contains(code) }
    func modifierIsDown(_ flag: CGEventFlags) -> Bool { flagsDown.contains(flag) }
    func postedKeyVisible(_ key: KeySpec) -> (hid: Bool, session: Bool) {
        if key.modifierOnly, let flag = key.named?.flag { return (flagsDown.contains(flag), sessionFlagsDown.contains(flag)) }
        return (keysDown.contains(key.code), sessionKeysDown.contains(key.code))
    }
}

final class FakeProbes: Probes {
    var pids: [pid_t] = [100]
    var window: WindowState = .none("no window (pid 100)")
    var micTool: Bool? = true
    var micDevice: Bool? = true
    var front = "front=test"
    var calls = 0
    func processIDs(ofProvider id: String) -> [pid_t] { calls += 1; return pids }
    func windows(of pids: [pid_t]) -> WindowState { calls += 1; return pids.isEmpty ? .unknown("not running") : window }
    func micInUse(by pids: [pid_t]?) -> Bool? { calls += 1; return pids == nil ? micDevice : micTool }
    func frontApp() -> String { front }
}

final class FakeSink: Sink {
    var lines: [String] = []
    var traces: [String] = []
    var keepTraces = true  // false: nobody streams the debug log, the string must not be built
    var reports: [(phase: String, detail: String)] = []
    var states: [(trusted: Bool, tapActive: Bool)] = []
    func log(_ line: String) { lines.append(line) }
    func trace(_ msg: @autoclosure @escaping () -> String) { if keepTraces { traces.append(msg()) } }
    func report(_ phase: String, _ detail: String) { reports.append((phase, detail)) }
    func state(trusted: Bool, tapActive: Bool) { states.append((trusted, tapActive)) }
    func sourceName(_ id: String) -> String { "Name(\(id))" }
    var summaries: [String] { lines.filter { $0.hasPrefix("dictation ") } }
    func has(_ text: String) -> Bool { lines.contains { $0.contains(text) } }
}

/// FolderEvents, driven by hand: no FSEvents, no latency, no sleep (Sources/Core/Watch.swift, WatchTests.swift).
final class FakeFolderEvents: FolderEvents {
    private(set) var startCalls = 0
    private(set) var startedRoots: [String] = []
    private(set) var onChange: (() -> Void)?
    @discardableResult func start(roots: [String], latency: Double, onChange: @escaping () -> Void) -> Bool {
        startCalls += 1
        startedRoots = roots
        guard !roots.isEmpty else { return false }
        self.onChange = onChange
        return true
    }
    /// Simulate a change: what FSEvents would have reported, right now, with no latency.
    func fire() { onChange?() }
}

/// One Engine with all six fakes. The default plan is WeType-like: Fn is the trigger and the talk key, hold mode.
final class Rig {
    static let fn = KeySpec.named("fn")!
    static let english = "com.apple.keylayout.ABC"
    static let voice = "com.tencent.inputmethod.wetype.pinyin"

    var plan: Plan
    var planReads = 0  // how many times Engine called the plan closure (review-5 #3: this stands in for a provider's file read)
    let clock = FakeClock()
    let keys = FakeKeys()
    let sources: FakeSources
    let tap = FakeTap()
    let probes = FakeProbes()
    let sink = FakeSink()
    private(set) var engine: Engine!

    init(toggle: Bool = false, switchesInput: Bool = true, trigger: KeySpec = Rig.fn, current: String? = Rig.english, start: Bool = true) {
        plan = Plan(
            trigger: trigger, providerID: Rig.voice, switchesInput: switchesInput, voiceID: Rig.voice, voiceName: "WeType",
            forwardKey: Rig.fn, style: "hold", toggle: toggle, stopOnAnyKey: true,
            holdDelay: 0.2, restoreTimeout: 5.0, fallbackDelay: 2.5)
        sources = FakeSources(current)
        engine = Engine(
            plan: { [unowned self] in
                self.planReads += 1; return self.plan
            },
            deps: Deps(keys: keys, sources: sources, tap: tap, probes: probes, clock: clock, sink: sink))
        if start { engine.start() }
    }

    /// The trigger as the tap reports it. A modifier key's edges are flagsChanged events with its flag and device bit.
    private func edge(_ down: Bool) -> KeyInput {
        let t = plan.trigger
        if t.modifierOnly, let n = t.named, let flag = n.flag {
            return KeyInput(kind: .flagsChanged, code: t.code, flags: down ? CGEventFlags(rawValue: flag.rawValue | n.device) : [])
        }
        return KeyInput(kind: down ? .keyDown : .keyUp, code: t.code, flags: t.flags)
    }
    @discardableResult func press() -> Bool { engine.handle(edge(true)) }
    @discardableResult func release() -> Bool { engine.handle(edge(false)) }
    /// Our own talk key (Fn) coming back through the tap: its press, then its release.
    func echo() {
        _ = engine.handle(KeyInput(kind: .flagsChanged, code: 63, flags: [.maskSecondaryFn], ours: true))
        _ = engine.handle(KeyInput(kind: .flagsChanged, code: 63, flags: [], ours: true))
    }
    @discardableResult func otherKey(_ code: Int = 36, down: Bool = true) -> Bool {
        engine.handle(KeyInput(kind: down ? .keyDown : .keyUp, code: code))
    }

    /// Press and hold. The talk key goes out at about 0.22 s (switch, then holdDelay); the first probe sample
    /// comes 0.3 s later. `hold` is the whole time the shortcut stays down. With `echo`, the talk key comes back.
    func pressUntilListening(hold: Double = 0.6, echo: Bool = true) {
        press(); clock.advance(0.3)
        XCTAssertEqual(engine.machine.state, .listening, "setup: the talk key was sent")
        if echo { self.echo() }
        if hold > 0.3 { clock.advance(hold - 0.3) }
    }
    /// A summary line with the timestamp the file would carry, for Stats.
    func lastEntry() -> DictationEntry? { sink.summaries.last.flatMap { DictationEntry.parse("2026-10-03 12:00:00.000 " + $0) } }
}
