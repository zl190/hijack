import AppKit
import ApplicationServices
import Carbon
import CoreAudio
import os

// MARK: live seams — the macOS side of Sources/Core/Seams.swift. Engine never calls the system directly.

extension Plan {
    init(_ m: Model) {
        let c = m.c, key = m.forwardKey
        self.init(trigger: m.customTrigger ?? key, providerID: m.provider.id, switchesInput: m.provider.switchesInputSource,
                  voiceID: m.voiceID, voiceName: m.voiceName, forwardKey: key, style: m.voiceStyle, toggle: m.toggleMode,
                  stopOnAnyKey: c.stopOnAnyKey, holdDelay: c.holdDelay, restoreTimeout: c.restoreTimeout, fallbackDelay: c.fallbackDelay)
    }
}

extension Engine {
    /// The app's engine: the real tap, TIS, CoreAudio, the window list, the main queue, the log file.
    static func live() -> Engine {
        let tap = LiveTap()
        let engine = Engine(plan: { Plan(Model.shared) },
                            deps: Deps(keys: LiveKeyPoster(), sources: LiveInputSources(), tap: tap, probes: LiveProbes(),
                                       clock: LiveScheduler(), sink: LiveSink()))
        tap.triggerCode = { [unowned engine] in engine.plan.trigger.code }
        return engine
    }
}

struct LiveKeyPoster: KeyPoster {
    @discardableResult func post(_ key: KeySpec, down: Bool) -> Bool {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key.code), keyDown: down) else { return false }
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
            return true
        }
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        e.post(tap: .cghidEventTap)
        return true
    }

    func postModifier(_ mod: Mod, down: Bool, held: Set<Mod>) {
        let code: Int = [.ctrl: 59, .option: 58, .shift: 56, .command: 55, .fn: 63][mod]!
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) else { return }
        e.type = .flagsChanged
        e.flags = held.reduce(into: CGEventFlags()) { $0.insert($1.flag) }
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        e.post(tap: .cghidEventTap)
    }
}

struct LiveInputSources: InputSources {
    func current() -> String? { currentID() }
    func select(_ id: String) -> Bool { selectSource(id) }
}

extension KeyInput {
    /// The tap's event, reduced. nil for event types the tap did not ask for.
    init?(_ type: CGEventType, _ event: CGEvent) {
        let kind: Kind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        case .tapDisabledByTimeout: kind = .tapDisabledByTimeout
        case .tapDisabledByUserInput: kind = .tapDisabledByUserInput
        default: return nil
        }
        self.init(kind: kind, code: Int(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags,
                  ours: event.getIntegerValueField(.eventSourceUserData) == marker)
    }
}

final class LiveTap: TapControl {
    var tap: CFMachPort?
    var onEvent: ((KeyInput) -> Bool)?
    var triggerCode: () -> Int = { -1 }   // for the slow-event line only

    var trusted: Bool { AXIsProcessTrusted() }
    var isEnabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    func enable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }
    func keyIsDown(_ code: Int) -> Bool { CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code)) }
    func modifierIsDown(_ flag: CGEventFlags) -> Bool { CGEventSource.flagsState(.hidSystemState).contains(flag) }
    var secureInputOn: Bool { IsSecureEventInputEnabled() }

    func install(_ onEvent: @escaping (KeyInput) -> Bool) -> Bool {
        self.onEvent = onEvent
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue | 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue),
            callback: { _, type, event, ctx in
                // A slow tap gets disabled by the system, and taps after ours see keys late: note where the time went.
                // Event timestamps are mach_absolute_time ticks. The key itself is never logged, only what kind it was.
                let entered = mach_absolute_time()
                let age = event.timestamp > 0 && entered > event.timestamp ? ticksToMs(entered - event.timestamp) : 0
                let live = Unmanaged<LiveTap>.fromOpaque(ctx!).takeUnretainedValue()
                guard let input = KeyInput(type, event) else { return Unmanaged.passUnretained(event) }
                let tapSpan = signposter.beginInterval("key event", id: .exclusive)
                let pass = live.onEvent?(input) ?? true
                signposter.endInterval("key event", tapSpan)
                let spent = ticksToMs(mach_absolute_time() - entered)
                if age > 100 || spent > 100 {
                    let kind = input.ours ? "our talk key" : input.code == live.triggerCode() ? "the shortcut" : "another key"
                    log("slow key event (\(kind)): \(Int(age))ms old on arrival, handled in \(Int(spent))ms")
                }
                return pass ? Unmanaged.passUnretained(event) : nil
            }, userInfo: me)
        else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        return true
    }
}

struct LiveProbes: Probes {
    func processIDs(ofProvider id: String) -> [pid_t] { voiceProvider(for: id).processIDs() }
    func windows(of pids: [pid_t]) -> WindowState { onScreenWindows(of: pids) }
    func micInUse(by pids: [pid_t]?) -> Bool? { micInUseLive(by: pids) }
    func frontApp() -> String { frontAppLive() }
}

struct LiveScheduler: Scheduler {
    var now: Date { Date() }
    func after(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    func offMain<T>(_ work: @escaping () -> T, then done: @escaping (T) -> Void) {
        DispatchQueue.global(qos: .utility).async { let v = work(); DispatchQueue.main.async { done(v) } }
    }
}

struct LiveSink: Sink {
    func log(_ line: String) { fileLog(line) }
    func trace(_ msg: @autoclosure @escaping () -> String) { debugTrace(msg()) }
    func report(_ phase: String, _ detail: String) {
        NotificationCenter.default.post(name: .hijackActivity, object: nil, userInfo: ["phase": phase, "detail": detail])
    }
    func state(trusted: Bool, tapActive: Bool) {
        AppState.write(trusted: trusted, tapActive: tapActive)
        // The menu bar icon (Idle/Off) follows this even when no menu is open (docs/hci-review-faults.md §3.1).
        NotificationCenter.default.post(name: .hijackStateChanged, object: nil)
    }
    func sourceName(_ id: String) -> String { voiceProvider(for: id).name }
}

// Free-function names that a method of the same name can reach without recursion.
func selectSource(_ id: String) -> Bool { select(id) }
func frontAppLive() -> String { frontApp() }
func fileLog(_ line: String) { log(line) }
func debugTrace(_ msg: @autoclosure @escaping () -> String) { trace(msg()) }

let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
func ticksToMs(_ ticks: UInt64) -> Double { Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e6 }

/// Is the microphone in use — by these processes (nil: by anyone, on the default input device)?
/// Per-process needs macOS 14.2; returns nil when it can't tell.
func micInUseLive(by pids: [pid_t]?) -> Bool? {
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

extension Notification.Name {
    static let hijackActivity = Notification.Name("HijackActivity")
    static let hijackSettingsChanged = Notification.Name("HijackSettingsChanged")
    static let hijackStateChanged = Notification.Name("HijackStateChanged")   // trusted / tapActive changed
}
