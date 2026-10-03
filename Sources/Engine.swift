import AppKit
import ApplicationServices
import Carbon
import CoreAudio
import ServiceManagement
import os

// MARK: key handling

/// Timing marks for Instruments (Points of Interest): one interval per dictation, its phases, and key moments.
/// Free when nothing is recording. `scripts/sequence.sh` turns a recording into the sequence diagram.
let signposter = OSSignposter(subsystem: "com.zl190.hijack", category: .pointsOfInterest)

/// Everything a session needs from the settings, read off the key tap's path: the settings come from disk
/// (config file, the voice tool's own settings), and the tap shares the main thread with a timeout.
struct Plan {
    var trigger: KeySpec
    var provider: VoiceProvider
    var voiceID: String
    var voiceName: String
    var forwardKey: KeySpec
    var style: String          // how the voice tool wants its key: "hold" | "tap" | "doubleTap"
    var toggle: Bool
    var stopOnAnyKey: Bool
    var holdDelay: Double
    var restoreTimeout: Double
    var fallbackDelay: Double

    init(_ m: Model) {
        let c = m.c, key = m.forwardKey
        trigger = m.customTrigger ?? key
        provider = m.provider; voiceID = m.voiceID; voiceName = m.voiceName
        forwardKey = key; style = m.voiceStyle; toggle = m.toggleMode; stopOnAnyKey = c.stopOnAnyKey
        holdDelay = c.holdDelay; restoreTimeout = c.restoreTimeout; fallbackDelay = c.fallbackDelay
    }
}

/// What one dictation did, for the single line it leaves in the log.
struct DictationRecord {
    var pressedAt: Date = Date()
    var keySentMs: Int?          // shortcut down → talk key sent (nil: released before it was sent)
    var echoMs: Int?             // shortcut down → our talk key's press came back through our own tap
    var releasedAt: Date?
    var heldMic: (tool: Bool?, device: Bool?)?   // last sample while the talk key was held
    var heldWindow: WindowState?                 // same sample
    var sawWindow: Bool = false        // its voice window was on screen at some point after release
    var windowGoneMs: Int?       // release → voice window gone (the text is in)
}

final class Engine {
    let m: Model = .shared
    private(set) var plan: Plan = Plan(Model.shared)
    var previous: String?
    var generation: Int = 0
    var physicalDown: Bool = false          // the shortcut as the keyboard has it (edges go to the machine)
    var machine: SessionMachine = SessionMachine()   // what a press does: Sources/Core/SessionMachine.swift
    var mode: SessionMode = SessionMode()   // fixed per press
    var record: DictationRecord = DictationRecord()
    var waited: TimeInterval = 0            // release → switch back, for the summary
    var voicePIDs: [pid_t] = []             // the voice tool's processes, looked up once per dictation: listing running apps asks other processes, too slow to repeat every 50 ms
    var tap: CFMachPort?
    var span: (id: OSSignpostID, dictation: OSSignpostIntervalState, phase: (name: StaticString, state: OSSignpostIntervalState))?

    var swallowUp: Int?               // key that stopped a toggle session: also eat its key-up
    var paused: Bool = false                // the settings window is recording a key: let every key through
    var waitingReported: Bool = false

    /// Re-read the settings, between sessions only, so a change mid-session can't strand a held key.
    func refresh() {
        guard machine.state == .idle, !physicalDown else { return }
        plan = Plan(m)
    }

    // Live progress for the settings window's "Try it" area.
    func report(_ phase: String, _ detail: String = "") {
        NotificationCenter.default.post(name: .hijackActivity, object: nil, userInfo: ["phase": phase, "detail": detail])
    }

    // Turn the session into what the voice method expects: hold its key, or tap / double-tap it.
    func tapKey(after delay: Double = 0) {
        let key = plan.forwardKey
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            post(key, down: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [self] in post(key, down: false) }
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
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key.code), keyDown: down) else {
            log("couldn't create the \(key.name) \(down ? "press" : "release") event"); return
        }
        if key.modifierOnly, let n = key.named, let flag = n.flag {
            e.type = .flagsChanged
            e.flags = down ? CGEventFlags(rawValue: flag.rawValue | n.device) : []
        } else {
            // A combo: modifiers go down before the key and come up after it, like real hands.
            let mods = Mod.allCases.filter { key.mods.contains($0) }
            if down { for (i, mod) in mods.enumerated() { postModifier(mod, down: true, held: Set(mods.prefix(i + 1))) } }
            e.flags = key.flags
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
            if !down { for (i, mod) in mods.enumerated().reversed() { postModifier(mod, down: false, held: Set(mods.prefix(i))) } }
            return
        }
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        e.post(tap: .cghidEventTap)
    }

    func postModifier(_ mod: Mod, down: Bool, held: Set<Mod>) {
        let code: Int = [.ctrl: 59, .option: 58, .shift: 56, .command: 55, .fn: 63][mod]!
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) else { return }
        e.type = .flagsChanged
        e.flags = held.reduce(into: CGEventFlags()) { $0.insert($1.flag) }
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        e.post(tap: .cghidEventTap)
    }

    func ms(since d: Date) -> Int { Int(Date().timeIntervalSince(d) * 1000) }

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
        voicePIDs = plan.provider.processIDs()
        record.keySentMs = ms(since: record.pressedAt)
        enterPhase("listening"); mark("talk key sent")
        startVoice()
        sampleWhileHeld(gen: generation, after: 0.3)
        report("listening", plan.voiceName)
        trace("forward \(self.plan.forwardKey.name) start (\(self.plan.style)) after \(self.record.keySentMs ?? 0)ms")
    }

    /// Hand an event to the state machine and carry out what it returns. Returns whether the key event passes.
    @discardableResult
    func run(_ event: SessionEvent, keyCode: Int? = nil) -> Bool {
        let p = plan
        if event == .press {
            // The shortcut is the tool's own key and the tool is already in front: it gets the real key.
            let sameKey = p.trigger == p.forwardKey && !p.toggle && p.style == "hold"
            mode = SessionMode(toggle: p.toggle, switchesInput: p.provider.switchesInputSource,
                               passthrough: sameKey && (!p.provider.switchesInputSource || currentID() == p.voiceID))
        }
        let before = machine.state
        let effects = machine.handle(event, mode)
        let after = machine.state
        trace("\(event.rawValue): \(before.rawValue) → \(after.rawValue) \(effects.map { "\($0)" })")
        if (before == .starting || before == .listening) && (machine.state == .waitingForText || machine.state == .idle) {
            record.releasedAt = Date(); enterPhase("waiting for text")
        }
        var pass = false
        for effect in effects {
            switch effect {
            case .passKey: pass = true
            case .swallowKey: pass = false
            case .swallowKeyAndItsRelease: pass = false; swallowUp = keyCode
            case .finishPrevious: summary(end: "interrupted by the next press")   // the retry after a failure must not erase it
            case .begin:
                generation += 1; record = DictationRecord(); voicePIDs = []; beginDictation()
            case .switchToVoice:
                let cur = currentID()
                if let cur, cur != p.voiceID { previous = cur }
                // After the tap returns: nothing slow inside the tap, every tap after ours would wait for it.
                if cur != p.voiceID { DispatchQueue.main.async { switchTo(p.voiceID, "switch to") } }
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
    func scheduleTalkKey() {
        let p = plan, gen = generation, start = Date()
        func whenReady() {
            guard machine.state == .starting, gen == generation else { trace("released before forward"); return }
            let ready = !p.provider.switchesInputSource || currentID() == p.voiceID
            let waited = Date().timeIntervalSince(start)
            if (ready && waited >= p.holdDelay) || waited >= maxSwitchWait {
                if !ready { trace("input source not ready after \(Int(waited * 1000))ms, sending anyway") }
                run(.keySent)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { whenReady() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { whenReady() }
    }

    /// Watch the voice window: when it goes (plus a short grace), or the wait runs out, the text is in.
    func waitForText() {
        let p = plan, gen = generation, released = record.releasedAt ?? Date()
        var windowGone: Date?
        func poll() {
            guard gen == generation, machine.state == .waitingForText else { return }
            let waited = Date().timeIntervalSince(released)
            if voicePIDs.isEmpty { voicePIDs = p.provider.processIDs() }   // released before the key was sent
            let visible = onScreenWindows(of: voicePIDs).busy
            if visible == true { record.sawWindow = true }
            if record.sawWindow && windowGone == nil && visible == false { windowGone = Date(); record.windowGoneMs = ms(since: released); mark("window gone") }
            let graceDone = windowGone.map { Date().timeIntervalSince($0) >= capsuleGrace } ?? false
            guard graceDone || waited >= (record.sawWindow ? p.restoreTimeout : p.fallbackDelay) else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }; return
            }
            self.waited = waited
            run(.textDone)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
    }

    /// The dictation is over: write its line; an input method also switches back to where you were.
    func finish() {
        let p = plan
        guard p.provider.switchesInputSource else { summary(end: "no switch back needed"); report("done", p.voiceName); return }
        guard currentID() == p.voiceID, let prev = previous else {
            summary(end: "input source already changed, not switched back"); report("done", ""); return
        }
        summary(end: "back after \(String(format: "%.2f", waited))s")
        switchTo(prev, "restore")
        report("done", L("等上屏 \(String(format: "%.1f", waited)) 秒，已切回 \(voiceProvider(for: prev).name)", "waited \(String(format: "%.1f", waited))s for the text, back to \(voiceProvider(for: prev).name)"))
    }

    /// While the talk key is held: is the voice tool listening, and is its window up? Sampled every half
    /// second off the main thread (CoreAudio and the window list are slow for a key tap); release keeps the last.
    func sampleWhileHeld(gen: Int, after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard machine.state == .listening, gen == generation else { return }
            let pids = voicePIDs, watched = plan.provider.switchesInputSource
            DispatchQueue.global(qos: .utility).async {
                let mic = (micInUse(by: pids), micInUse(by: nil))
                let window: WindowState = watched ? onScreenWindows(of: pids) : .unknown("an app: its window isn't watched")
                DispatchQueue.main.async { [self] in
                    guard gen == generation else { return }
                    record.heldMic = mic; record.heldWindow = window
                    sampleWhileHeld(gen: gen, after: 0.5)
                }
            }
        }
    }

    // The one line per dictation that goes to the file. When it didn't work, the checks tell which step failed:
    // the key never went out (echo), the voice tool didn't start listening (mic), or we missed its window.
    func summary(end: String) {
        let p = plan, r = record
        let held = (r.releasedAt ?? Date()).timeIntervalSince(r.pressedAt)
        var line = "dictation \(p.voiceName) (\(p.toggle ? "toggle" : "hold")): held \(String(format: "%.2f", held))s"
        if let sent = r.keySentMs {
            func onOff(_ b: Bool?) -> String { b.map { $0 ? "on" : "off" } ?? "?" }
            line += ", \(p.forwardKey.name) sent after \(sent)ms"
            if p.provider.switchesInputSource { line += r.windowGoneMs.map { ", window closed \($0)ms after release" } ?? ", window never closed after release" }
            line += ", \(end)"
            line += " | echo \(r.echoMs.map { "after \($0)ms" } ?? "missing"), mic tool \(onOff(r.heldMic?.tool)) device \(onOff(r.heldMic?.device))"
            if p.provider.switchesInputSource { line += ", window while held: \(r.heldWindow?.text ?? "?")" }
        } else {
            line += ", released before \(p.forwardKey.name) was sent"
        }
        if let tap, !CGEvent.tapIsEnabled(tap: tap) { line += ", key tap disabled" }
        if IsSecureEventInputEnabled() { line += ", secure input on" }
        log(line + " | \(frontApp())")
        endDictation()
    }

    /// The tap was off for a while, so key events may have been missed: line our idea of the trigger up with
    /// the keyboard. A missed release would leave the talk key held and the next press swallowed.
    func reconcile() {
        let downNow = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(plan.trigger.code))
        guard downNow != physicalDown else { return }
        log("trigger is \(downNow ? "down" : "up") but we had it \(physicalDown ? "down" : "up"): catching up")
        physicalDown = downNow
        if !downNow && machine.isActive && !plan.toggle { run(.release) }
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            signposter.emitEvent("tap disabled")
            log("event tap was disabled by the system (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabled")
            DispatchQueue.main.async { [self] in reconcile() }
            return Unmanaged.passUnretained(event)
        }
        let p = plan
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if event.getIntegerValueField(.eventSourceUserData) == marker {
            // Our own talk key came back through our tap: it was posted. Count only its press.
            if code == p.forwardKey.code, record.echoMs == nil, isPress(type, event, p.forwardKey) { record.echoMs = ms(since: record.pressedAt); mark("echo") }
            return Unmanaged.passUnretained(event)
        }
        guard !paused else { return Unmanaged.passUnretained(event) }
        if type == .keyUp, code == swallowUp { swallowUp = nil; return nil }
        // Toggle session running: any other key stops it, and is not typed (Return must not send a message).
        if machine.isActive && p.toggle && p.stopOnAnyKey && type == .keyDown && code != p.trigger.code {
            return run(.otherKey, keyCode: code) ? Unmanaged.passUnretained(event) : nil
        }
        let trigger = p.trigger
        guard code == trigger.code else { return Unmanaged.passUnretained(event) }
        let down: Bool
        if trigger.modifierOnly {
            guard type == .flagsChanged, let n = trigger.named, let flag = n.flag else { return Unmanaged.passUnretained(event) }
            down = n.device == 0 ? event.flags.contains(flag) : event.flags.rawValue & n.device != 0
        } else {
            guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
            let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn]
            if type == .keyDown && !physicalDown && event.flags.intersection(relevant) != trigger.flags.intersection(relevant) {
                return Unmanaged.passUnretained(event)    // same key, different modifiers: not ours
            }
            down = type == .keyDown
        }
        // A release whose press we never saw (the tap was off): not ours to swallow, or the key stays down for everyone.
        if !down && !physicalDown { return Unmanaged.passUnretained(event) }
        // A repeat while held: the tool's own key keeps its repeats, ours are swallowed.
        if down == physicalDown { return machine.state == .passthrough ? Unmanaged.passUnretained(event) : nil }
        physicalDown = down
        return run(down ? .press : .release) ? Unmanaged.passUnretained(event) : nil
    }

    func isPress(_ type: CGEventType, _ event: CGEvent, _ key: KeySpec) -> Bool {
        if type == .keyDown { return true }
        guard type == .flagsChanged, let flag = key.named?.flag else { return false }
        return event.flags.contains(flag)
    }

    func start() {
        guard AXIsProcessTrusted() else {
            if !waitingReported { AppState.write(trusted: false, tapActive: false); waitingReported = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }   // wait for the grant
            return
        }
        plan = Plan(m)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue | 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue),
            callback: { _, type, event, ctx in
                // A slow tap gets disabled by the system, and taps after ours see keys late: note where the time went.
                // Event timestamps are mach_absolute_time ticks. The key itself is never logged, only what kind it was.
                let entered = mach_absolute_time()
                let age = event.timestamp > 0 && entered > event.timestamp ? ticksToMs(entered - event.timestamp) : 0
                let engine = Unmanaged<Engine>.fromOpaque(ctx!).takeUnretainedValue()
                let tapSpan = signposter.beginInterval("key event", id: .exclusive)
                let result = engine.handle(type, event)
                signposter.endInterval("key event", tapSpan)
                let spent = ticksToMs(mach_absolute_time() - entered)
                if age > 100 || spent > 100 {
                    let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
                    let kind = event.getIntegerValueField(.eventSourceUserData) == marker ? "our talk key"
                        : code == engine.plan.trigger.code ? "the shortcut" : "another key"
                    log("slow key event (\(kind)): \(Int(age))ms old on arrival, handled in \(Int(spent))ms")
                }
                return result
            }, userInfo: me)
        else { AppState.write(trusted: true, tapActive: false); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }; return }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        AppState.write(trusted: true, tapActive: true)
        log("started: trigger \(plan.trigger.name), forward \(plan.forwardKey.name), voice \(plan.voiceID)")
    }
}

let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
func ticksToMs(_ ticks: UInt64) -> Double { Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e6 }

/// Is the microphone in use — by these processes (nil: by anyone, on the default input device)?
/// Per-process needs macOS 14.2; returns nil when it can't tell.
func micInUse(by pids: [pid_t]?) -> Bool? {
    let system = AudioObjectID(kAudioObjectSystemObject)
    func get<T: BitwiseCopyable>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr
    }
    guard let pids else {
        var dev = AudioDeviceID(0), running = UInt32(0)
        guard get(system, kAudioHardwarePropertyDefaultInputDevice, &dev), dev != 0,
              get(dev, kAudioDevicePropertyDeviceIsRunningSomewhere, &running) else { return nil }
        return running != 0
    }
    guard #available(macOS 14.2, *), !pids.isEmpty else { return nil }
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return nil }
    for obj in objects {
        var pid = pid_t(0), input = UInt32(0)
        if get(obj, kAudioProcessPropertyPID, &pid), pids.contains(pid), get(obj, kAudioProcessPropertyIsRunningInput, &input), input != 0 { return true }
    }
    return false
}

extension Notification.Name { static let hijackActivity = Notification.Name("HijackActivity") }
