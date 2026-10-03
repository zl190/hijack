import Foundation
import CoreGraphics
import os

// MARK: engine — carries out what the state machine decides, through the seams in Seams.swift.
// No live system call in this file. The app injects them (Sources/System.swift); the tests inject fakes.

let capsuleGrace = 0.15  // after its voice window disappears, wait this long, then switch back
let maxSwitchWait = 1.0  // give up waiting for the input source switch after this long

/// Timing marks for Instruments (Points of Interest): one interval per dictation, its phases, and key moments.
/// Free when nothing is recording. `scripts/sequence.sh` turns a recording into the sequence diagram.
let signposter = OSSignposter(subsystem: "com.zl190.hijack", category: .pointsOfInterest)

/// Everything a session needs from the settings, read once per session. The app builds it from `Model`.
struct Plan: Equatable {
    var trigger: KeySpec
    var providerID: String     // the voice tool, for its processes
    var switchesInput: Bool    // an input method: switch to it and back. false: an app with its own hotkey
    var voiceID: String
    var voiceName: String
    var forwardKey: KeySpec
    var style: String          // how the voice tool wants its key: "hold" | "tap" | "doubleTap"
    var toggle: Bool
    var stopOnAnyKey: Bool
    var holdDelay: Double
    var restoreTimeout: Double
    var fallbackDelay: Double
}

/// What one dictation did, for the single line it leaves in the log.
struct DictationRecord {
    var pressedAt: Date
    var keySentMs: Int?          // shortcut down → talk key sent (nil: released before it was sent)
    var echoMs: Int?             // shortcut down → our talk key's press came back through our own tap
    var releasedAt: Date?
    var heldMic: (tool: Bool?, device: Bool?)?   // last sample while the talk key was held
    var heldWindow: WindowState?                 // same sample
    var sawWindow: Bool = false        // its voice window was on screen at some point after release
    var windowGoneMs: Int?       // release → voice window gone (the text is in)
    var switchFailed: Bool = false   // the input source never switched: the talk key was not sent (FM-05)
}

final class Engine {
    let makePlan: () -> Plan
    let keys: KeyPoster
    let sources: InputSources
    let tap: TapControl
    let probes: Probes
    let clock: Scheduler
    let sink: Sink

    private(set) var plan: Plan
    var previous: String?                   // the input source to restore after this dictation
    var generation: Int = 0
    var physicalDown: Bool = false          // the shortcut as the keyboard has it (edges go to the machine)
    var machine: SessionMachine = SessionMachine()   // what a press does: Sources/Core/SessionMachine.swift
    var mode: SessionMode = SessionMode()   // fixed per press
    var record: DictationRecord
    var waited: TimeInterval = 0            // release → switch back, for the summary
    var voicePIDs: [pid_t] = []             // the voice tool's processes, looked up once per dictation: listing running apps asks other processes, too slow to repeat every 50 ms
    var tapInstalled: Bool = false
    var span: (id: OSSignpostID, dictation: OSSignpostIntervalState, phase: (name: StaticString, state: OSSignpostIntervalState))?

    var swallowUp: Int?               // key that stopped a toggle session: also eat its key-up
    var paused: Bool = false                // the settings window is recording a key: let every key through
    var waitingReported: Bool = false

    init(plan: @escaping () -> Plan, deps: Deps) {
        makePlan = plan
        keys = deps.keys; sources = deps.sources; tap = deps.tap; probes = deps.probes; clock = deps.clock; sink = deps.sink
        self.plan = plan()
        record = DictationRecord(pressedAt: deps.clock.now)
    }

    func log(_ line: String) { sink.log(line) }
    func trace(_ msg: String) { sink.trace(msg) }

    /// Re-read the settings, between sessions only, so a change mid-session can't strand a held key.
    func refresh() {
        guard machine.state == .idle, !physicalDown else { return }
        plan = makePlan()
    }

    // Live progress for the settings window's "Try it" area.
    func report(_ phase: String, _ detail: String = "") { sink.report(phase, detail) }

    // Turn the session into what the voice method expects: hold its key, or tap / double-tap it.
    func tapKey(after delay: Double = 0) {
        let key = plan.forwardKey
        clock.after(delay) { [self] in
            post(key, down: true)
            clock.after(0.03) { [self] in post(key, down: false) }
        }
    }
    func startVoice() {
        switch plan.style {
        case "tap": tapKey()
        case "doubleTap": tapKey(); tapKey(after: 0.12)
        default: post(plan.forwardKey, down: true)
        }
    }
    func endVoice() {
        if plan.style == "hold" { post(plan.forwardKey, down: false) } else { tapKey() }   // "press any key to finish"
    }

    func post(_ key: KeySpec, down: Bool) {
        if !keys.post(key, down: down) { log("couldn't create the \(key.name) \(down ? "press" : "release") event") }
    }

    func ms(since d: Date) -> Int { Int(clock.now.timeIntervalSince(d) * 1000) }

    // Phases of one dictation: "starting" (press → talk key sent), "listening" (→ release), "waiting for text" (→ switch back).
    func beginDictation() {
        let id = signposter.makeSignpostID()
        span = (id, signposter.beginInterval("dictation", id: id), ("starting", signposter.beginInterval("starting", id: id)))
    }
    func enterPhase(_ name: StaticString) {
        guard let s = span else { return }
        signposter.endInterval(s.phase.name, s.phase.state)
        span?.phase = (name, signposter.beginInterval(name, id: s.id))
    }
    func endDictation() {
        guard let s = span else { return }
        signposter.endInterval(s.phase.name, s.phase.state)
        signposter.endInterval("dictation", s.dictation)
        span = nil
    }
    func mark(_ name: StaticString) { if let s = span { signposter.emitEvent(name, id: s.id) } }

    func sendKey() {
        voicePIDs = probes.processIDs(ofProvider: plan.providerID)
        record.keySentMs = ms(since: record.pressedAt)
        enterPhase("listening"); mark("talk key sent")
        startVoice()
        sampleWhileHeld(gen: generation, after: 0.3)
        report("listening", plan.voiceName)
        trace("forward \(self.plan.forwardKey.name) start (\(self.plan.style)) after \(self.record.keySentMs ?? 0)ms")
    }

    /// Select and confirm: re-read the current source a moment later and retry once if it didn't stick.
    func switchTo(_ id: String, _ label: String) {
        let ok = sources.select(id)
        clock.after(0.1) { [self] in
            if sources.current() == id { trace("\(label) \(id) ok=\(ok)") }
            else { log("\(label) \(id) didn't stick, retry ok=\(sources.select(id))") }
        }
    }

    /// Hand an event to the state machine and carry out what it returns. Returns whether the key event passes.
    @discardableResult
    func run(_ event: SessionEvent, keyCode: Int? = nil) -> Bool {
        let p = plan
        if event == .press {
            // The shortcut is the tool's own key and the tool is already in front: it gets the real key.
            let sameKey = p.trigger == p.forwardKey && !p.toggle && p.style == "hold"
            mode = SessionMode(toggle: p.toggle, switchesInput: p.switchesInput,
                               passthrough: sameKey && (!p.switchesInput || sources.current() == p.voiceID))
        }
        let before = machine.state
        let effects = machine.handle(event, mode)
        let after = machine.state
        trace("\(event.rawValue): \(before.rawValue) → \(after.rawValue) \(effects.map { "\($0)" })")
        if (before == .starting || before == .listening) && (machine.state == .waitingForText || machine.state == .idle) {
            record.releasedAt = clock.now; enterPhase("waiting for text")
        }
        defer { if machine.state == .idle { refresh() } }   // settings changed mid-dictation apply now
        var pass = false
        for effect in effects {
            switch effect {
            case .passKey: pass = true
            case .swallowKey: pass = false
            case .swallowKeyAndItsRelease: pass = false; swallowUp = keyCode
            case .finishPrevious: summary(end: "interrupted by the next press")   // the retry after a failure must not erase it
            case .begin:
                generation += 1; record = DictationRecord(pressedAt: clock.now); voicePIDs = []; previous = nil; beginDictation()
            case .switchToVoice:
                let cur = sources.current()
                if let cur, cur != p.voiceID { previous = cur }
                // After the tap returns: nothing slow inside the tap, every tap after ours would wait for it.
                if cur != p.voiceID { clock.after(0) { [self] in switchTo(p.voiceID, "switch to") } }
                report("switching", p.voiceName)
            case .scheduleTalkKey: scheduleTalkKey()
            case .sendTalkKey: sendKey()
            case .releaseTalkKey: endVoice()
            case .waitForText: report("finishing", p.voiceName); waitForText()
            case .finish: finish()
            }
        }
        return pass
    }

    /// Send the talk key once the input source is ready and the hold delay is over (an app: after the delay).
    /// When the source is still wrong after `maxSwitchWait`, the dictation ends without the talk key (FM-05).
    func scheduleTalkKey() {
        let p = plan, gen = generation, start = clock.now
        func whenReady() {
            guard machine.state == .starting, gen == generation else { trace("released before forward"); return }
            let ready = !p.switchesInput || sources.current() == p.voiceID
            let waited = clock.now.timeIntervalSince(start)
            if ready && waited >= p.holdDelay {
                run(.keySent)
            } else if waited >= maxSwitchWait {
                record.switchFailed = true
                log("input source never switched to \(p.voiceID) after \(Int(waited * 1000))ms, talk key not sent")
                run(.switchFailed)
            } else {
                clock.after(0.02) { whenReady() }
            }
        }
        clock.after(0.02) { whenReady() }
    }

    /// Watch the voice window: when it goes (plus a short grace), or the wait runs out, the text is in.
    func waitForText() {
        let p = plan, gen = generation, released = record.releasedAt ?? clock.now
        var windowGone: Date?
        func poll() {
            guard gen == generation, machine.state == .waitingForText else { return }
            let waited = clock.now.timeIntervalSince(released)
            if voicePIDs.isEmpty { voicePIDs = probes.processIDs(ofProvider: p.providerID) }   // released before the key was sent
            let visible = probes.windows(of: voicePIDs).busy
            if visible == true { record.sawWindow = true }
            if record.sawWindow && windowGone == nil && visible == false { windowGone = clock.now; record.windowGoneMs = ms(since: released); mark("window gone") }
            let graceDone = windowGone.map { clock.now.timeIntervalSince($0) >= capsuleGrace } ?? false
            guard graceDone || waited >= (record.sawWindow ? p.restoreTimeout : p.fallbackDelay) else {
                clock.after(0.05) { poll() }; return
            }
            self.waited = waited
            run(.textDone)
        }
        clock.after(0.05) { poll() }
    }

    /// The dictation is over: write its line; an input method also switches back to where you were.
    func finish() {
        let p = plan
        if record.switchFailed { summary(end: "input source never switched"); report("done", ""); return }
        guard p.switchesInput else { summary(end: "no switch back needed"); report("done", p.voiceName); return }
        guard let prev = previous else { summary(end: "started inside \(p.voiceName), nothing to switch back to"); report("done", p.voiceName); return }
        guard sources.current() == p.voiceID else {
            summary(end: "input source already changed, not switched back"); report("done", ""); return
        }
        summary(end: "back after \(String(format: "%.2f", waited))s")
        switchTo(prev, "restore")
        let name = sink.sourceName(prev)
        report("done", localize("等上屏 \(String(format: "%.1f", waited)) 秒，已切回 \(name)", "waited \(String(format: "%.1f", waited))s for the text, back to \(name)"))
    }

    /// While the talk key is held: is the voice tool listening, and is its window up? Sampled every half
    /// second off the main thread (CoreAudio and the window list are slow for a key tap); release keeps the last.
    func sampleWhileHeld(gen: Int, after delay: Double) {
        clock.after(delay) { [self] in
            guard machine.state == .listening, gen == generation else { return }
            let pids = voicePIDs, watched = plan.switchesInput, probes = probes
            clock.offMain({ () -> ((Bool?, Bool?), WindowState) in
                let mic = (probes.micInUse(by: pids), probes.micInUse(by: nil))
                let window: WindowState = watched ? probes.windows(of: pids) : .unknown("an app: its window isn't watched")
                return (mic, window)
            }) { [self] mic, window in
                guard gen == generation else { return }
                record.heldMic = mic; record.heldWindow = window
                sampleWhileHeld(gen: gen, after: 0.5)
            }
        }
    }

    // The one line per dictation that goes to the file. When it didn't work, the checks tell which step failed:
    // the key never went out (echo), the voice tool didn't start listening (mic), or we missed its window.
    func summary(end: String) {
        let p = plan, r = record
        let held = (r.releasedAt ?? clock.now).timeIntervalSince(r.pressedAt)
        var line = "dictation \(p.voiceName) (\(p.toggle ? "toggle" : "hold")): held \(String(format: "%.2f", held))s"
        if let sent = r.keySentMs {
            func onOff(_ b: Bool?) -> String { b.map { $0 ? "on" : "off" } ?? "?" }
            line += ", \(p.forwardKey.name) sent after \(sent)ms"
            if p.switchesInput { line += r.windowGoneMs.map { ", window closed \($0)ms after release" } ?? ", window never closed after release" }
            line += ", \(end)"
            line += " | echo \(r.echoMs.map { "after \($0)ms" } ?? "missing"), mic tool \(onOff(r.heldMic?.tool)) device \(onOff(r.heldMic?.device))"
            if p.switchesInput { line += ", window while held: \(r.heldWindow?.text ?? "?")" }
        } else if r.switchFailed {
            line += ", \(end)"
        } else {
            line += ", released before \(p.forwardKey.name) was sent"
        }
        if tapInstalled, !tap.isEnabled { line += ", key tap disabled" }
        if tap.secureInputOn { line += ", secure input on" }
        log(line + " | \(probes.frontApp())")
        endDictation()
    }

    /// The tap was off for a while, so key events may have been missed: line our idea of the trigger up with
    /// the keyboard. A missed release would leave the talk key held and the next press swallowed.
    func reconcile() {
        let downNow = tap.keyIsDown(plan.trigger.code)
        guard downNow != physicalDown else { return }
        log("trigger is \(downNow ? "down" : "up") but we had it \(physicalDown ? "down" : "up"): catching up")
        physicalDown = downNow
        if !downNow && machine.isActive && !plan.toggle { run(.release) }
    }

    /// After sleep or unlock the voice tool and the input sources are in an unknown state (FM-25).
    /// A session that was running stops now, in hold and in toggle mode. Then the trigger is reconciled.
    func reconcileAfterWake(_ reason: String) {
        if machine.isActive {
            log("session was active across \(reason): stopping it")
            run(plan.toggle ? .press : .release)
        }
        physicalDown = tap.keyIsDown(plan.trigger.code)
    }

    /// The forward key as the system has it. A crash while the talk key was held leaves it down (FM-10).
    func clearStuckModifier() {
        guard !physicalDown else { return }
        let key = plan.forwardKey
        let down = key.modifierOnly ? key.named?.flag.map { tap.modifierIsDown($0) } ?? false : tap.keyIsDown(key.code)
        guard down else { return }
        post(key, down: false)
        log("cleared a stuck \(key.name)")
    }

    /// Re-enable the tap and check that it took (FM-02). One retry on the next run-loop turn; state.json tells the menu.
    func reenableTap(_ why: String) {
        tap.enable()
        signposter.emitEvent("tap disabled")
        if tap.isEnabled {
            log("event tap was disabled by the system (\(why)), re-enabled")
        } else {
            log("event tap was disabled by the system (\(why)), re-enable failed, retrying")
            sink.state(trusted: true, tapActive: false)
            clock.after(0) { [self] in
                tap.enable()
                let ok = tap.isEnabled
                sink.state(trusted: true, tapActive: ok)
                log(ok ? "event tap re-enabled on retry" : "event tap still disabled after retry")
            }
        }
        clock.after(0) { [self] in reconcile() }
    }

    /// One key event from the tap. Returns true when the event passes to the system, false when Engine swallows it.
    func handle(_ input: KeyInput) -> Bool {
        if input.kind == .tapDisabledByTimeout || input.kind == .tapDisabledByUserInput {
            reenableTap(input.kind == .tapDisabledByTimeout ? "timeout" : "user input")
            return true
        }
        let p = plan
        let code = input.code
        if input.ours {
            // Our own talk key came back through our tap: it was posted. Count only its press.
            if code == p.forwardKey.code, record.echoMs == nil, isPress(input, p.forwardKey) { record.echoMs = ms(since: record.pressedAt); mark("echo") }
            return true
        }
        guard !paused else { return true }
        if input.kind == .keyUp, code == swallowUp { swallowUp = nil; return false }
        // Toggle session running: any other key stops it, and is not typed (Return must not send a message).
        if machine.isActive && p.toggle && p.stopOnAnyKey && input.kind == .keyDown && code != p.trigger.code {
            return run(.otherKey, keyCode: code)
        }
        let trigger = p.trigger
        guard code == trigger.code else { return true }
        let down: Bool
        if trigger.modifierOnly {
            guard input.kind == .flagsChanged, let n = trigger.named, let flag = n.flag else { return true }
            down = n.device == 0 ? input.flags.contains(flag) : input.flags.rawValue & n.device != 0
        } else {
            guard input.kind == .keyDown || input.kind == .keyUp else { return true }
            let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn]
            if input.kind == .keyDown && !physicalDown && input.flags.intersection(relevant) != trigger.flags.intersection(relevant) {
                return true    // same key, different modifiers: not ours
            }
            down = input.kind == .keyDown
        }
        // A release whose press we never saw (the tap was off): not ours to swallow, or the key stays down for everyone.
        if !down && !physicalDown { return true }
        // A repeat while held: the tool's own key keeps its repeats, ours are swallowed.
        if down == physicalDown { return machine.state == .passthrough }
        physicalDown = down
        return run(down ? .press : .release)
    }

    func isPress(_ input: KeyInput, _ key: KeySpec) -> Bool {
        if input.kind == .keyDown { return true }
        guard input.kind == .flagsChanged, let flag = key.named?.flag else { return false }
        return input.flags.contains(flag)
    }

    func start() {
        guard tap.trusted else {
            if !waitingReported { sink.state(trusted: false, tapActive: false); waitingReported = true }
            clock.after(1) { self.start() }   // wait for the grant
            return
        }
        plan = makePlan()
        guard tap.install({ [unowned self] input in self.handle(input) }) else {
            sink.state(trusted: true, tapActive: false); clock.after(1) { self.start() }; return
        }
        tapInstalled = true
        tap.enable()
        let on = tap.isEnabled
        sink.state(trusted: true, tapActive: on)
        if !on { log("event tap installed but not enabled") }
        clearStuckModifier()
        log("started: trigger \(plan.trigger.name), forward \(plan.forwardKey.name), voice \(plan.voiceID)")
    }
}
