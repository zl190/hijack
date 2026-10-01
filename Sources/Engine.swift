import AppKit
import ApplicationServices
import Carbon
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
    var tap: CFMachPort?

    var trigger = KeySpec(code: 61)   // snapshot per session, so a config change mid-session can't strand it
    var active = false                // a voice session is running (hold: key held · toggle: between taps)
    var swallowUp: Int?               // key that stopped a toggle session: also eat its key-up

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
        sawWindow = false
        let cur = currentID()
        if m.isApp {   // a voice app: no input-source switch, just press its key
            if trigger == m.forwardKey && !m.toggleMode && m.voiceStyle == "hold" { passthrough = true; log("down: trigger is \(m.voiceName)'s own key, pass through"); return true }
            passthrough = false
            log("down: \(m.voiceName) \(focusDesc())")
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + m.c.holdDelay) { [self] in
                guard active, gen == generation else { log("released before forward"); return }
                forwarded = true; startVoice(); log("forward \(m.forwardKey.name) start (\(m.voiceStyle))")
            }
            return false
        }
        // Already in the voice method and the trigger is its own key: let it see the real key.
        if cur == m.voiceID && trigger == m.forwardKey && !m.toggleMode && m.voiceStyle == "hold" {
            passthrough = true; log("down: already voice IME, pass through"); return true
        }
        passthrough = false
        if let cur, cur != m.voiceID { previous = cur }
        log("down: \(cur ?? "?") \(focusDesc())")
        if cur != m.voiceID { switchTo(m.voiceID, "switch to") }
        let gen = generation, start = Date()
        func forwardWhenReady() {
            guard active, gen == generation else { log("released before forward"); return }
            let ready = currentID() == m.voiceID
            let waited = Date().timeIntervalSince(start)
            if (ready && waited >= m.c.holdDelay) || waited >= maxSwitchWait {
                forwarded = true
                startVoice()
                log("forward \(m.forwardKey.name) start (\(m.voiceStyle)) after \(Int(waited * 1000))ms ready=\(ready) \(focusDesc())")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { forwardWhenReady() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { forwardWhenReady() }
        return false
    }

    func released() -> Bool {
        if passthrough { passthrough = false; log("up: pass through"); return true }
        if forwarded { endVoice(); forwarded = false; log("forward end (\(m.voiceStyle)) \(focusDesc())") }
        if m.isApp { return false }   // nothing to switch back
        let gen = generation, released = Date()
        var capsuleGone: Date?
        func restoreWhenDone() {
            guard gen == generation else { return }
            let waited = Date().timeIntervalSince(released)
            let visible = voiceWindowVisible(m.voiceID)
            if visible == true { sawWindow = true }
            if sawWindow && capsuleGone == nil && visible == false { capsuleGone = Date(); log("voice window gone after \(Int(waited * 1000))ms") }
            let graceDone = capsuleGone.map { Date().timeIntervalSince($0) >= capsuleGrace } ?? false
            guard graceDone || waited >= (sawWindow ? m.c.restoreTimeout : m.c.fallbackDelay) else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { restoreWhenDone() }; return
            }
            guard currentID() == m.voiceID, let prev = previous else { return }
            log("restore after \(Int(waited * 1000))ms, held \(Int(released.timeIntervalSince(pressedAt)))s, \(focusDesc())")
            switchTo(prev, "restore")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { restoreWhenDone() }
        return false
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log("event tap was disabled by the system (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != marker else { return Unmanaged.passUnretained(event) }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp, code == swallowUp { swallowUp = nil; return nil }
        // Toggle session running: any other key stops it, and is not typed (Return must not send a message).
        if active && m.toggleMode && m.c.stopOnAnyKey && type == .keyDown && code != trigger.code {
            log("stopped by keyCode \(code)")
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
        if down != physicalDown { log("trigger \(down ? "down" : "up") (session \(active ? "running" : "idle"), \(m.toggleMode ? "toggle" : "hold"))") }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }   // wait for the grant
            return
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue | 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue),
            callback: { _, type, event, ctx in
                Unmanaged<Engine>.fromOpaque(ctx!).takeUnretainedValue().handle(type, event)
            }, userInfo: me)
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }; return }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("started: trigger \(m.trigger.name), forward \(m.forwardKey.name), voice \(m.voiceID)")
    }
}
