import HijackCore
import AppKit
import ApplicationServices
import Carbon
import CoreAudio
import os
import Darwin

// MARK: live seams — the macOS side of Sources/Core/Seams.swift. Engine never calls the system directly.

extension Plan {
    init(_ m: Model) {
        let c = m.c, key = m.forwardKey
        self.init(
            trigger: m.customTrigger ?? key, providerID: m.provider.id, switchesInput: m.provider.switchesInputSource,
            voiceID: m.voiceID, voiceName: m.voiceName, forwardKey: key, style: m.voiceStyle, toggle: m.toggleMode,
            stopOnAnyKey: c.stopOnAnyKey, holdDelay: c.holdDelay, restoreTimeout: c.restoreTimeout, fallbackDelay: c.fallbackDelay)
    }
}

extension Engine {
    /// The app's engine: the real tap, TIS, CoreAudio, the window list, the main queue, the log file.
    static func live() -> Engine {
        let tap = LiveTap()
        let engine = Engine(
            plan: { Plan(Model.shared) },
            deps: Deps(
                keys: LiveKeyPoster(), sources: LiveInputSources(), tap: tap, probes: LiveProbes(),
                clock: LiveScheduler(), sink: LiveSink(), supervisor: LiveSupervisor()))
        tap.triggerCode = { [unowned engine] in engine.plan.trigger.code }
        return engine
    }
}

/// Posts through one explicit HID-state event source instead of the implicit one (`keyboardEventSource: nil`).
/// The implicit source goes stale in a long-lived process after system sleep: posts stop reaching the HID
/// stream (docs/incidents/2026-10-04-echo-missing.md). `rebuild` swaps in a fresh source.
final class LiveKeyPoster: KeyPoster {
    private var source = CGEventSource(stateID: .hidSystemState)
    private var warnedNoSource = false

    /// `CGEventSource(stateID:)` can fail: then the old source stays (it may still work), and the line says so.
    func rebuild(reason: String) {
        if let fresh = CGEventSource(stateID: .hidSystemState) {
            source = fresh
            log("event source rebuilt (\(reason))")
        } else {
            log("event source rebuild failed (\(reason)), keeping the old one")
        }
    }

    /// Creates the event through the explicit source. With none (only if the very first creation failed)
    /// it says so once and posts with the implicit source, as before W7.
    private func makeEvent(_ code: Int, down: Bool) -> CGEvent? {
        if source == nil, !warnedNoSource {
            warnedNoSource = true
            log("no event source, posting with the implicit one")
        }
        return CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
    }

    @discardableResult func post(_ key: KeySpec, down: Bool) -> Bool {
        guard let e = makeEvent(key.code, down: down) else { return false }
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
        // An exhaustive switch, not a dictionary force-unwrap: a new Mod case fails to compile here
        // instead of crashing at runtime (no sound fallback key code exists for an unknown modifier).
        let code: Int
        switch mod {
        case .ctrl: code = 59
        case .option: code = 58
        case .shift: code = 56
        case .command: code = 55
        case .fn: code = 63
        }
        guard let e = makeEvent(code, down: down) else { return }
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
        self.init(
            kind: kind, code: Int(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags,
            ours: event.getIntegerValueField(.eventSourceUserData) == marker)
    }
}

final class LiveTap: TapControl {
    var tap: CFMachPort?
    var onEvent: ((KeyInput) -> Bool)?
    var triggerCode: () -> Int = { -1 }  // for the slow-event line only

    var trusted: Bool { AXIsProcessTrusted() }
    var isEnabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    func enable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }
    func keyIsDown(_ code: Int) -> Bool { CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code)) }
    func modifierIsDown(_ flag: CGEventFlags) -> Bool { CGEventSource.flagsState(.hidSystemState).contains(flag) }
    func listenersAhead(for key: KeySpec) -> [String]? {
        if case .ahead(let names) = keyListenerChain(of: getpid(), modifierKey: key.modifierOnly) { return names }
        return nil
    }
    var secureInputOn: Bool { IsSecureEventInputEnabled() }

    func install(_ onEvent: @escaping (KeyInput) -> Bool) -> Bool {
        self.onEvent = onEvent
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard
            let tap = CGEvent.tapCreate(
                tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(
                    1 << CGEventType.flagsChanged.rawValue | 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue),
                callback: { _, type, event, ctx in
                    // A slow tap gets disabled by the system, and taps after ours see keys late: note where the time went.
                    // Event timestamps are mach_absolute_time ticks. The key itself is never logged, only what kind it was.
                    let entered = mach_absolute_time()
                    let age = event.timestamp > 0 && entered > event.timestamp ? ticksToMs(entered - event.timestamp) : 0
                    // CGEvent.tapCreate always echoes back the userInfo we gave it (never nil in practice);
                    // guard anyway, because a missing context must never swallow a key.
                    guard let ctx else {
                        log("key tap callback: nil context, passing the key through")
                        return Unmanaged.passUnretained(event)
                    }
                    let live = Unmanaged<LiveTap>.fromOpaque(ctx).takeUnretainedValue()
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

/// W10 (docs/adr/0023): the system's event-tap list as rows, judged by `keyListenerChain` (Sources/Core). The list is
/// kept newest-first for taps pushed to the head (measured 2026-10-19 with two listen-only taps of one process: the
/// younger one was listed first and fired first; the same order for filtering taps across processes is inferred, see
/// docs/incidents). Limit: a tap appended at the tail is also listed before older head taps yet runs after them; the
/// names tell a reader which case it is. One window-server call (2 ms p50, 12 ms max at load 30), no I/O; the Engine
/// calls it off the main thread, never inside the tap callback. 128 rows is plenty (21 on this Mac); past that, ours
/// may fall off the list and read as `.notListed`.
func keyListenerChain(of pid: pid_t, modifierKey: Bool) -> KeyListenerChain {
    let flagsMask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
    let keysMask: CGEventMask = 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue
    var count: UInt32 = 0
    var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: 128)
    guard CGGetEventTapList(128, &taps, &count) == .success else { return .unreadable }
    let rows = taps.prefix(Int(count)).map {
        TapRow(
            pid: $0.tappingProcess, hidLevel: $0.tapPoint == .cghidEventTap, enabled: $0.enabled,
            filtering: $0.options == .defaultTap, watchesFlags: $0.eventsOfInterest & flagsMask != 0,
            watchesKeys: $0.eventsOfInterest & keysMask != 0)
    }
    let ourStart = processStart(pid)
    return keyListenerChain(
        rows: rows, ours: pid, modifierKey: modifierKey, name: processName,
        startedBeforeUs: { other in
            guard let ourStart, let theirs = processStart(other) else { return nil }
            return theirs < ourStart
        })
}

private func processName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX) * 4)  // PROC_PIDPATHINFO_MAXSIZE
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "pid \(pid)" }
    return URL(fileURLWithPath: String(cString: buf)).lastPathComponent
}

/// When the process started, as (seconds, microseconds) since the epoch; nil when the kernel will not say (gone, or not ours to see).
private func processStart(_ pid: pid_t) -> (UInt64, UInt64)? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return (info.pbi_start_tvsec, info.pbi_start_tvusec)
}

struct LiveProbes: Probes {
    func processIDs(ofProvider id: String) -> [pid_t] { voiceProvider(for: id).processIDs() }
    func windows(of pids: [pid_t]) -> WindowState { onScreenWindows(of: pids) }
    func micInUse(by pids: [pid_t]?) -> Bool? { micInUseLive(by: pids) }
    func frontApp() -> String { frontAppLive() }
    // W9: App Nap, read without root. XNU's TASK_SUPPRESSION_POLICY (flavor 3, osfmk/mach/task_policy_private.h) is
    // 16 integer_t words; word 0 is `active` (1: App Nap engaged). Flavor 4 (TASK_POLICY_STATE) is root-only: never use it.
    // Flavor 1 is TASK_CATEGORY_POLICY: word 0 is the task role.
    func processState() -> ProcessState? {
        var raw = [integer_t](repeating: 0, count: 16)
        var count = mach_msg_type_number_t(16)
        var getDefault: boolean_t = 0
        let kr = raw.withUnsafeMutableBufferPointer {
            task_policy_get(mach_task_self_, task_policy_flavor_t(3), $0.baseAddress, &count, &getDefault)
        }
        var cat = [integer_t](repeating: 0, count: 1)
        var catCount = mach_msg_type_number_t(1)
        var catDefault: boolean_t = 0
        let kr2 = cat.withUnsafeMutableBufferPointer {
            task_policy_get(mach_task_self_, task_policy_flavor_t(1), $0.baseAddress, &catCount, &catDefault)
        }
        guard kr == KERN_SUCCESS else { return nil }
        return ProcessState(napped: raw[0] != 0, role: kr2 == KERN_SUCCESS ? Int(cat[0]) : nil)
    }
}

struct LiveScheduler: Scheduler {
    var now: Date { Date() }
    func after(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    func offMain<T>(_ work: @escaping () -> T, then done: @escaping (T) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let v = work(); DispatchQueue.main.async { done(v) }
        }
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

let timebase: mach_timebase_info_data_t = {
    var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
}()
func ticksToMs(_ ticks: UInt64) -> Double { Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e6 }

/// Is the microphone in use — by these processes (nil: by anyone, on the default input device)?
/// Per-process needs macOS 14.2; returns nil when it can't tell.
func micInUseLive(by pids: [pid_t]?) -> Bool? {
    let system = AudioObjectID(kAudioObjectSystemObject)
    func get<T: BitwiseCopyable>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr
    }
    guard let pids else {
        var dev = AudioDeviceID(0), running = UInt32(0)
        guard get(system, kAudioHardwarePropertyDefaultInputDevice, &dev), dev != 0,
            get(dev, kAudioDevicePropertyDeviceIsRunningSomewhere, &running)
        else { return nil }
        return running != 0
    }
    guard #available(macOS 14.2, *), !pids.isEmpty else { return nil }
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return nil }
    for obj in objects {
        var pid = pid_t(0), input = UInt32(0)
        if get(obj, kAudioProcessPropertyPID, &pid), pids.contains(pid), get(obj, kAudioProcessPropertyIsRunningInput, &input), input != 0 {
            return true
        }
    }
    return false
}

extension Notification.Name {
    static let hijackActivity = Notification.Name("HijackActivity")
    static let hijackSettingsChanged = Notification.Name("HijackSettingsChanged")
    static let hijackStateChanged = Notification.Name("HijackStateChanged")  // trusted / tapActive changed
}

/// The one relaunch path (review-4 M4): a detached `open -b` once this process is gone, because
/// openApplication(at:) alone would activate the copy that is still running. The menu's Reopen action and the
/// self-relaunch (W8) both go through here; `selfInitiated` marks the exit so the next `started:` line says so.
/// The shell waits for our pid to disappear (capped at 10 s, then opens anyway and the instance lock decides)
/// instead of sleeping a fixed time. Returns false, without quitting, when the relauncher cannot be spawned.
/// The quit itself runs on the next main-loop turn, so the caller can still record that the spawn worked.
@discardableResult
func relaunchProcess(selfInitiated: Bool) -> Bool {
    if selfInitiated { UserDefaults.standard.set(true, forKey: LiveSupervisor.markKey) }
    let reopen = Process()
    reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
    reopen.arguments = [
        "-c",
        "n=0; while kill -0 \(getpid()) 2>/dev/null && [ $n -lt 100 ]; do sleep 0.1; n=$((n+1)); done; open -b com.zl190.hijack",
    ]
    do {
        try reopen.run()
    } catch {
        UserDefaults.standard.removeObject(forKey: LiveSupervisor.markKey)
        log("self-relaunch aborted: couldn't spawn the relauncher (\(error))")
        return false
    }
    DispatchQueue.main.async {
        flushLog()  // the log is written on a background queue, and terminate() ends in exit()
        NSApp.terminate(nil)
    }
    return true
}

/// W8: relaunch through `relaunchProcess`; the last-relaunch time and the exit mark live in UserDefaults.
final class LiveSupervisor: Supervisor {
    static let markKey = "selfRelaunchMark"
    static let atKey = "selfRelaunchAt"
    func relaunch(reason: String) -> Bool { relaunchProcess(selfInitiated: true) }
    var lastRelaunchAt: Date? {
        get { UserDefaults.standard.object(forKey: LiveSupervisor.atKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: LiveSupervisor.atKey) }
    }
    /// main.swift reads and clears the UserDefaults mark right after the CLI dispatch (a process that dies before
    /// `start()` must not leave it behind) and keeps the answer here until the `started:` line asks once.
    static var consumedMark = false
    static func consumeMarkFromDefaults() -> Bool {
        let marked = UserDefaults.standard.bool(forKey: markKey)
        if marked { UserDefaults.standard.removeObject(forKey: markKey) }
        consumedMark = marked
        return marked
    }
    func takeSelfRelaunchMark() -> Bool { defer { LiveSupervisor.consumedMark = false }; return LiveSupervisor.consumedMark }
}
