import AppKit
import ApplicationServices
import Carbon
import CoreAudio
import ServiceManagement

// MARK: key handling

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
    var physicalDown: Bool = false
    var forwarded: Bool = false
    var passthrough: Bool = false
    var record: DictationRecord = DictationRecord()
    var restoring: Bool = false             // waiting for the text before switching back
    var tap: CFMachPort?

    var active: Bool = false                // a voice session is running (hold: key held · toggle: between taps)
    var swallowUp: Int?               // key that stopped a toggle session: also eat its key-up
    var paused: Bool = false                // the settings window is recording a key: let every key through
    var waitingReported: Bool = false

    /// Re-read the settings, between sessions only, so a change mid-session can't strand a held key.
    func refresh() {
        guard !active, !physicalDown, !restoring else { return }
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

    func sendKey() {
        forwarded = true
        record.keySentMs = ms(since: record.pressedAt)
        startVoice()
        sampleWhileHeld(gen: generation, after: 0.3)
        report("listening", plan.voiceName)
        trace("forward \(self.plan.forwardKey.name) start (\(self.plan.style)) after \(self.record.keySentMs ?? 0)ms")
    }

    func pressed() -> Bool {
        if restoring { summary(end: "interrupted by the next press") }   // the retry after a failure must not erase it
        restoring = false
        generation += 1
        record = DictationRecord()
        let p = plan, gen = generation
        if !p.provider.switchesInputSource {   // a voice app: no input-source switch, just press its key
            if p.trigger == p.forwardKey && !p.toggle && p.style == "hold" { passthrough = true; trace("down: trigger is \(p.voiceName)'s own key, pass through"); return true }
            passthrough = false
            trace("down: \(p.voiceName)")
            DispatchQueue.main.asyncAfter(deadline: .now() + p.holdDelay) { [self] in
                guard active, gen == generation else { trace("released before forward"); return }
                sendKey()
            }
            return false
        }
        let cur = currentID()
        // Already in the voice method and the trigger is its own key: let it see the real key.
        if cur == p.voiceID && p.trigger == p.forwardKey && !p.toggle && p.style == "hold" {
            passthrough = true; trace("down: already voice IME, pass through"); return true
        }
        passthrough = false
        if let cur, cur != p.voiceID { previous = cur }
        trace("down: \(cur ?? "?")")
        // After the tap returns: nothing slow inside the tap, every tap after ours would wait for it.
        if cur != p.voiceID { DispatchQueue.main.async { switchTo(p.voiceID, "switch to") } }
        report("switching", p.voiceName)
        let start = Date()
        func forwardWhenReady() {
            guard active, gen == generation else { trace("released before forward"); return }
            let ready = currentID() == p.voiceID
            let waited = Date().timeIntervalSince(start)
            if (ready && waited >= p.holdDelay) || waited >= maxSwitchWait {
                if !ready { trace("input source not ready after \(Int(waited * 1000))ms, sending anyway") }
                sendKey()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { forwardWhenReady() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { forwardWhenReady() }
        return false
    }

    func released() -> Bool {
        if passthrough { passthrough = false; trace("up: pass through"); return true }
        let p = plan
        record.releasedAt = Date()
        if forwarded { endVoice(); forwarded = false; trace("forward end (\(p.style))") }
        if !p.provider.switchesInputSource {   // nothing to switch back
            summary(end: "no switch back needed")
            report("done", p.voiceName); return false
        }
        report("finishing", p.voiceName)
        restoring = true
        let gen = generation, released = record.releasedAt!
        var windowGone: Date?
        func restoreWhenDone() {
            guard gen == generation else { return }
            let waited = Date().timeIntervalSince(released)
            let visible = p.provider.isBusy()
            if visible == true { record.sawWindow = true }
            if record.sawWindow && windowGone == nil && visible == false { windowGone = Date(); record.windowGoneMs = ms(since: released) }
            let graceDone = windowGone.map { Date().timeIntervalSince($0) >= capsuleGrace } ?? false
            guard graceDone || waited >= (record.sawWindow ? p.restoreTimeout : p.fallbackDelay) else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { restoreWhenDone() }; return
            }
            restoring = false
            guard currentID() == p.voiceID, let prev = previous else {
                summary(end: "input source already changed, not switched back")
                report("done", ""); return
            }
            summary(end: "back after \(String(format: "%.2f", waited))s")
            switchTo(prev, "restore")
            report("done", L("等上屏 \(String(format: "%.1f", waited)) 秒，已切回 \(voiceProvider(for: prev).name)", "waited \(String(format: "%.1f", waited))s for the text, back to \(voiceProvider(for: prev).name)"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { restoreWhenDone() }
        return false
    }

    /// While the talk key is held: is the voice tool listening, and is its window up? Sampled every half
    /// second off the main thread (CoreAudio and the window list are slow for a key tap); release keeps the last.
    func sampleWhileHeld(gen: Int, after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard forwarded, gen == generation else { return }
            let provider = plan.provider, pids = provider.processIDs()   // input-source lookups: main thread only
            let watched = provider.switchesInputSource
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
        var line = "dictation \(p.voiceName) (\(p.toggle ? "toggle" : "hold")): held \(String(format: "%.1f", held))s"
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
    }

    /// The tap was off for a while, so key events may have been missed: line our idea of the trigger up with
    /// the keyboard. A missed release would leave the talk key held and the next press swallowed.
    func reconcile() {
        let downNow = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(plan.trigger.code))
        guard downNow != physicalDown else { return }
        log("trigger is \(downNow ? "down" : "up") but we had it \(physicalDown ? "down" : "up"): catching up")
        physicalDown = downNow
        if !downNow && active && !plan.toggle { active = false; _ = released() }
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log("event tap was disabled by the system (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabled")
            DispatchQueue.main.async { [self] in reconcile() }
            return Unmanaged.passUnretained(event)
        }
        let p = plan
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if event.getIntegerValueField(.eventSourceUserData) == marker {
            // Our own talk key came back through our tap: it was posted. Count only its press.
            if code == p.forwardKey.code, record.echoMs == nil, isPress(type, event, p.forwardKey) { record.echoMs = ms(since: record.pressedAt) }
            return Unmanaged.passUnretained(event)
        }
        guard !paused else { return Unmanaged.passUnretained(event) }
        if type == .keyUp, code == swallowUp { swallowUp = nil; return nil }
        // Toggle session running: any other key stops it, and is not typed (Return must not send a message).
        if active && p.toggle && p.stopOnAnyKey && type == .keyDown && code != p.trigger.code {
            trace("stopped by another key")
            active = false; swallowUp = code; _ = released()
            return nil
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
        var pass = passthrough
        if down != physicalDown { trace("trigger \(down ? "down" : "up") (session \(self.active ? "running" : "idle"), \(p.toggle ? "toggle" : "hold"))") }
        if down && !physicalDown {
            physicalDown = true
            if !active { active = true; pass = pressed() }                    // hold or toggle: start
            else if p.toggle { active = false; pass = released() }            // toggle: second tap stops
        } else if !down && physicalDown {
            physicalDown = false
            if active && !p.toggle { active = false; pass = released() }      // hold: release stops
            else if p.toggle { pass = false }
        }
        return pass ? Unmanaged.passUnretained(event) : nil   // key repeats while held are swallowed too
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
                let result = engine.handle(type, event)
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
