import AppKit
import ApplicationServices
import Carbon
import CoreAudio
import ServiceManagement

// MARK: key handling

final class Engine {
    let m = Model.shared
    var previous: String?
    var generation = 0
    var physicalDown = false
    var forwarded = false
    var passthrough = false
    var pressedAt = Date()
    var sawWindow = false   // the voice method showed a window during this press
    var echoed = false      // our own posted talk key came back through the tap (it was really posted)
    var micOn: Bool?        // the microphone was running while the talk key was held; nil = can't tell
    var fnAfter: Int?       // ms from pressing the shortcut to sending the talk key (nil: never sent)
    var tap: CFMachPort?

    var trigger = KeySpec(code: 61)   // snapshot per session, so a config change mid-session can't strand it
    var active = false                // a voice session is running (hold: key held · toggle: between taps)
    var swallowUp: Int?               // key that stopped a toggle session: also eat its key-up
    var paused = false                // the settings window is recording a key: let every key through
    var waitingReported = false

    // Live progress for the settings window's "Try it" area.
    func report(_ phase: String, _ detail: String = "") {
        NotificationCenter.default.post(name: .hijackActivity, object: nil, userInfo: ["phase": phase, "detail": detail])
    }

    // Turn the session into what the voice method expects: hold its key, or tap / double-tap it.
    func tapKey(after delay: Double = 0) {
        let key = m.forwardKey
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            post(key, down: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [self] in post(key, down: false) }
        }
    }
    func startVoice() {
        switch m.voiceStyle {
        case "tap": tapKey()
        case "doubleTap": tapKey(); tapKey(after: 0.12)
        default: post(m.forwardKey, down: true)
        }
    }
    func endVoice() {
        if m.voiceStyle == "hold" { post(m.forwardKey, down: false) } else { tapKey() }   // "press any key to finish"
    }

    func post(_ key: KeySpec, down: Bool) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key.code), keyDown: down) else { return }
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

    func pressed() -> Bool {
        generation += 1
        pressedAt = Date()
        sawWindow = false; echoed = false; micOn = nil; fnAfter = nil
        let cur = currentID()
        if !m.provider.switchesInputSource {   // a voice app: no input-source switch, just press its key
            if trigger == m.forwardKey && !m.toggleMode && m.voiceStyle == "hold" { passthrough = true; trace("down: trigger is \(m.voiceName)'s own key, pass through"); return true }
            passthrough = false
            trace("down: \(m.voiceName)")
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + m.c.holdDelay) { [self] in
                guard active, gen == generation else { trace("released before forward"); return }
                forwarded = true; fnAfter = Int(Date().timeIntervalSince(pressedAt) * 1000); startVoice(); trace("forward \(m.forwardKey.name) start (\(m.voiceStyle))")
                report("listening", m.voiceName)
            }
            return false
        }
        // Already in the voice method and the trigger is its own key: let it see the real key.
        if cur == m.voiceID && trigger == m.forwardKey && !m.toggleMode && m.voiceStyle == "hold" {
            passthrough = true; trace("down: already voice IME, pass through"); return true
        }
        passthrough = false
        if let cur, cur != m.voiceID { previous = cur }
        trace("down: \(cur ?? "?")")
        if cur != m.voiceID { switchTo(m.voiceID, "switch to") }
        report("switching", m.voiceName)
        let gen = generation, start = Date()
        func forwardWhenReady() {
            guard active, gen == generation else { trace("released before forward"); return }
            let ready = currentID() == m.voiceID
            let waited = Date().timeIntervalSince(start)
            if (ready && waited >= m.c.holdDelay) || waited >= maxSwitchWait {
                forwarded = true
                fnAfter = Int(Date().timeIntervalSince(pressedAt) * 1000)
                startVoice()
                report("listening", m.voiceName)
                trace("forward \(m.forwardKey.name) start (\(m.voiceStyle)) after \(Int(waited * 1000))ms ready=\(ready) \(focusDesc())")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in if gen == generation { micOn = micRunning() } }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { forwardWhenReady() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { forwardWhenReady() }
        return false
    }

    func released() -> Bool {
        if passthrough { passthrough = false; trace("up: pass through"); return true }
        if forwarded { endVoice(); forwarded = false; trace("forward end (\(m.voiceStyle))") }
        if !m.provider.switchesInputSource {   // nothing to switch back
            summary(heldFor: Date().timeIntervalSince(pressedAt), end: "no switch back needed")
            report("done", m.voiceName); return false
        }
        report("finishing", m.voiceName)
        let gen = generation, released = Date()
        var capsuleGone: Date?
        func restoreWhenDone() {
            guard gen == generation else { return }
            let waited = Date().timeIntervalSince(released)
            let visible = m.provider.isBusy()
            if visible == true { sawWindow = true }
            if sawWindow && capsuleGone == nil && visible == false { capsuleGone = Date(); trace("voice window gone after \(Int(waited * 1000))ms") }
            let graceDone = capsuleGone.map { Date().timeIntervalSince($0) >= capsuleGrace } ?? false
            guard graceDone || waited >= (sawWindow ? m.c.restoreTimeout : m.c.fallbackDelay) else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { restoreWhenDone() }; return
            }
            let held = released.timeIntervalSince(pressedAt)
            let textIn = capsuleGone.map { String(format: "text in %.2fs", $0.timeIntervalSince(released)) } ?? "no text signal"
            guard currentID() == m.voiceID, let prev = previous else {
                summary(heldFor: held, end: "\(textIn), input source already changed, not switched back")
                report("done", ""); return
            }
            summary(heldFor: held, end: "\(textIn), back after \(String(format: "%.2f", waited))s")
            switchTo(prev, "restore")
            report("done", L("等上屏 \(String(format: "%.1f", waited)) 秒，已切回 \(voiceProvider(for: prev).name)", "waited \(String(format: "%.1f", waited))s for the text, back to \(voiceProvider(for: prev).name)"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { restoreWhenDone() }
        return false
    }

    // The one line per dictation that goes to the file. When no voice window showed, the checks tell which
    // step failed: the key never went out (echo), the voice tool didn't start (mic), or we missed its window.
    func summary(heldFor held: TimeInterval, end: String) {
        let start = fnAfter.map { "\(m.forwardKey.name) after \(Int($0))ms" } ?? "released before \(m.forwardKey.name) was sent"
        var line = "dictation \(m.voiceName) (\(m.toggleMode ? "toggle" : "hold")): held \(String(format: "%.1f", held))s, \(start)"
        if fnAfter != nil {
            line += ", \(end) | echo \(echoed ? "seen" : "missing"), mic \(micOn.map { $0 ? "on" : "off" } ?? "unknown")"
            if m.provider.switchesInputSource { line += ", window \(sawWindow ? "seen" : "missing (" + m.provider.windowReport() + ")")" }
        }
        DispatchQueue.main.async { log(line + " | \(focusDesc())") }   // focus lookup is an AX call: never inside the tap
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log("event tap was disabled by the system (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == marker {
            if Int(event.getIntegerValueField(.keyboardEventKeycode)) == m.forwardKey.code { echoed = true }
            return Unmanaged.passUnretained(event)
        }
        guard !paused else { return Unmanaged.passUnretained(event) }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp, code == swallowUp { swallowUp = nil; return nil }
        // Toggle session running: any other key stops it, and is not typed (Return must not send a message).
        if active && m.toggleMode && m.c.stopOnAnyKey && type == .keyDown && code != trigger.code {
            trace("stopped by keyCode \(code)")
            active = false; swallowUp = code; _ = released()
            return nil
        }
        if !physicalDown && !active { trigger = m.trigger }   // config is read only between sessions
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
        var pass = passthrough
        if down != physicalDown { trace("trigger \(down ? "down" : "up") (session \(active ? "running" : "idle"), \(m.toggleMode ? "toggle" : "hold"))") }
        if down && !physicalDown {
            physicalDown = true
            if !active { active = true; pass = pressed() }                    // hold or toggle: start
            else if m.toggleMode { active = false; pass = released() }        // toggle: second tap stops
        } else if !down && physicalDown {
            physicalDown = false
            if active && !m.toggleMode { active = false; pass = released() }  // hold: release stops
            else if m.toggleMode { pass = false }
        }
        return pass ? Unmanaged.passUnretained(event) : nil   // key repeats while held are swallowed too
    }

    func start() {
        guard AXIsProcessTrusted() else {
            if !waitingReported { AppState.write(trusted: false, tapActive: false); waitingReported = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }   // wait for the grant
            return
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue | 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue),
            callback: { _, type, event, ctx in
                // Slow taps get disabled by the system, and other apps' taps see keys late: log where the time went.
                // Event timestamps are mach_absolute_time ticks, not nanoseconds.
                let entered = mach_absolute_time()
                let queued = event.timestamp > 0 && entered > event.timestamp ? ticksToMs(entered - event.timestamp) : 0
                let result = Unmanaged<Engine>.fromOpaque(ctx!).takeUnretainedValue().handle(type, event)
                let spent = ticksToMs(mach_absolute_time() - entered)
                if queued > 100 || spent > 100 {
                    log("slow key event: waited \(Int(queued))ms for the main thread, handled in \(Int(spent))ms (type \(type.rawValue), key \(event.getIntegerValueField(.keyboardEventKeycode)))")
                }
                return result
            }, userInfo: me)
        else { AppState.write(trusted: true, tapActive: false); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }; return }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        AppState.write(trusted: true, tapActive: true)
        log("started: trigger \(m.trigger.name), forward \(m.forwardKey.name), voice \(m.voiceID)")
    }
}

let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
func ticksToMs(_ ticks: UInt64) -> Double { Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e6 }

/// The default input device is in use by some process (the voice tool listening). nil = can't tell.
func micRunning() -> Bool? {
    var dev = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr, dev != 0 else { return nil }
    var running = UInt32(0); size = UInt32(MemoryLayout<UInt32>.size)
    addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &running) == noErr else { return nil }
    return running != 0
}

extension Notification.Name { static let hijackActivity = Notification.Name("HijackActivity") }
