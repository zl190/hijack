// Hijack — hold a key to dictate with a voice input method (default WeType) from any input source; the previous input source
// comes back after release. Settings live in ~/.config/hijack/config.json; the menu (menu bar icon, or
// open the app again) edits the common ones.
// Build: ./install.sh
import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

let appName = "Hijack"
let capsuleGrace = 0.15  // after its voice window disappears, wait this long, then switch back
let maxSwitchWait = 1.0  // give up waiting for the input source switch after this long
let marker: Int64 = 0x5357424B               // tags events we post ourselves
let weTypeID = "com.tencent.inputmethod.wetype.pinyin"

// MARK: language  (system by default; config can force English or Chinese)

func zh() -> Bool {
    switch Config.shared.language {
    case "zh": return true
    case "en": return false
    default: return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    }
}
func L(_ zhText: String, _ en: String) -> String { zh() ? zhText : en }

// MARK: keys — any key plus modifiers; a bare modifier key is a "modifier-only" key

enum Mod: String, CaseIterable { case ctrl, option, shift, command, fn
    var flag: CGEventFlags {
        switch self { case .ctrl: .maskControl; case .option: .maskAlternate; case .shift: .maskShift
                      case .command: .maskCommand; case .fn: .maskSecondaryFn }
    }
    var symbol: String {
        switch self { case .ctrl: "⌃"; case .option: "⌥"; case .shift: "⇧"; case .command: "⌘"; case .fn: "fn " }
    }
    // NSEvent.ModifierFlags bits, as WeType stores them
    var nsBit: Int { switch self { case .shift: 1 << 17; case .ctrl: 1 << 18; case .option: 1 << 19; case .command: 1 << 20; case .fn: 1 << 23 } }
}

struct NamedKey { let id: String; let code: Int; let zh: String; let en: String; let device: UInt64; let flag: CGEventFlags? }

let namedKeys: [NamedKey] = [
    NamedKey(id: "right_option", code: 61, zh: "右 Option", en: "Right Option", device: 0x40, flag: .maskAlternate),
    NamedKey(id: "left_option", code: 58, zh: "左 Option", en: "Left Option", device: 0x20, flag: .maskAlternate),
    NamedKey(id: "right_command", code: 54, zh: "右 Command", en: "Right Command", device: 0x10, flag: .maskCommand),
    NamedKey(id: "left_command", code: 55, zh: "左 Command", en: "Left Command", device: 0x08, flag: .maskCommand),
    NamedKey(id: "right_control", code: 62, zh: "右 Control", en: "Right Control", device: 0x2000, flag: .maskControl),
    NamedKey(id: "left_control", code: 59, zh: "左 Control", en: "Left Control", device: 0x01, flag: .maskControl),
    NamedKey(id: "right_shift", code: 60, zh: "右 Shift", en: "Right Shift", device: 0x04, flag: .maskShift),
    NamedKey(id: "left_shift", code: 56, zh: "左 Shift", en: "Left Shift", device: 0x02, flag: .maskShift),
    NamedKey(id: "fn", code: 63, zh: "Fn", en: "Fn", device: 0, flag: .maskSecondaryFn),
] + [("f13", 105), ("f14", 107), ("f15", 113), ("f16", 106), ("f17", 64), ("f18", 79), ("f19", 80), ("f20", 90), ("space", 49),
       ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9), ("b", 11),
       ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32), ("i", 34), ("p", 35),
       ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46), ("return", 36), ("tab", 48), ("escape", 53)]
    .map { NamedKey(id: $0.0, code: $0.1, zh: $0.0.uppercased(), en: $0.0.uppercased(), device: 0, flag: nil) }

// Menu quick picks; anything else goes in the config file.
let quickKeys = ["right_option", "left_option", "right_command", "fn"]

struct KeySpec: Equatable {
    var code: Int
    var mods: Set<Mod> = []
    var named: NamedKey? { namedKeys.first { $0.code == code } }
    var modifierOnly: Bool { mods.isEmpty && named?.flag != nil }
    var name: String {
        let base = named.map { L($0.zh, $0.en) } ?? "keyCode \(code)"
        return Mod.allCases.filter { mods.contains($0) }.map(\.symbol).joined() + base
    }
    var flags: CGEventFlags { mods.reduce(into: CGEventFlags()) { $0.insert($1.flag) } }
    static func named(_ id: String) -> KeySpec? { namedKeys.first { $0.id == id }.map { KeySpec(code: $0.code) } }

    // JSON: "right_option" | {"keyCode": 49, "modifiers": ["ctrl", "option"]}
    init(code: Int, mods: Set<Mod> = []) { self.code = code; self.mods = mods }
    init?(json: Any?) {
        if let s = json as? String, let k = KeySpec.named(s) { self = k; return }
        guard let d = json as? [String: Any] else { return nil }
        let code = (d["keyCode"] as? Int) ?? (d["key"] as? String).flatMap { KeySpec.named($0)?.code }
        guard let code else { return nil }
        self.code = code
        self.mods = Set(((d["modifiers"] as? [String]) ?? []).compactMap(Mod.init(rawValue:)))
    }
    var json: Any {
        if mods.isEmpty, let n = named { return n.id }
        var d: [String: Any] = named.map { ["key": $0.id] } ?? ["keyCode": code]
        d["modifiers"] = Mod.allCases.filter { mods.contains($0) }.map(\.rawValue)
        return d
    }
    var quickID: String? { mods.isEmpty ? named.map(\.id) : nil }

    // "option_left+space", "ctrl+shift+d" (Handy / Tauri-style bindings)
    init?(binding: String) {
        var mods: Set<Mod> = [], code: Int?
        for raw in binding.lowercased().split(separator: "+").map(String.init) {
            let base = raw.replacingOccurrences(of: "_left", with: "").replacingOccurrences(of: "_right", with: "")
            switch base {
            case "option", "alt": mods.insert(.option)
            case "command", "cmd", "super", "meta": mods.insert(.command)
            case "ctrl", "control": mods.insert(.ctrl)
            case "shift": mods.insert(.shift)
            case "fn": mods.insert(.fn)
            default: code = KeySpec.named(raw)?.code ?? KeySpec.named(base)?.code
            }
        }
        if let code { self.init(code: code, mods: mods) ; return }
        if binding.lowercased() == "fn" { self = KeySpec.named("fn")!; return }
        // A lone side-specific modifier, e.g. "option_right" → right_option
        let parts = binding.lowercased().split(separator: "_").map(String.init)
        guard parts.count == 2, ["left", "right"].contains(parts[1]) else { return nil }
        let base = ["alt": "option", "cmd": "command", "ctrl": "control"][parts[0]] ?? parts[0]
        guard let k = KeySpec.named("\(parts[1])_\(base)") else { return nil }
        self = k
    }
}

// WeType keeps its push-to-talk key in a private MMKV store; read it (never write it).
// MMKV layout: a little-endian UInt32 with the live data length, then the data; updates are appended,
// so the last occurrence inside the live range is current. Bytes past that length are stale leftovers.
// Values are [length][bytes]: keyCodes is a string like "[61]", modifiers a varint of NSEvent flags.
// Push-to-talk ("voicePTTShortcut_*") wins; if only the tap-to-toggle shortcut ("voiceToggleShortcut_*") is
// set, use that with tap or double-tap (tapCount). Returns the key and how to press it.
func weTypeVoice() -> (key: KeySpec, style: String)? {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WeType/mmkv/wetype.settings")
    guard let data = try? Data(contentsOf: url), data.count > 4 else { return nil }
    let live = Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
    guard live > 0, 4 + live <= data.count,
          let s = String(data: data.subdata(in: 4..<(4 + live)), encoding: .isoLatin1) else { return nil }
    func varint(_ name: String) -> Int? {
        guard let r = s.range(of: name, options: .backwards) else { return nil }
        var value = 0, shift = 0
        for b in s[r.upperBound...].unicodeScalars.prefix(6).map({ Int($0.value) }).dropFirst() {
            value |= (b & 0x7f) << shift; shift += 7; if b & 0x80 == 0 { break }
        }
        return value
    }
    func shortcut(_ prefix: String) -> KeySpec? {
        guard let r = s.range(of: prefix + "_keyCodes", options: .backwards) else { return nil }
        let tail = s[r.upperBound...].prefix(24)
        guard let open = tail.firstIndex(of: "["), let close = tail.firstIndex(of: "]"), open < close else { return nil }
        let codes = tail[tail.index(after: open)..<close].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard codes.count == 1 else { return nil }
        var key = KeySpec(code: codes[0])
        if !key.modifierOnly, let mods = varint(prefix + "_modifiers") { key.mods = Set(Mod.allCases.filter { mods & $0.nsBit != 0 }) }
        return key
    }
    if let k = shortcut("voicePTTShortcut") { return (k, "hold") }
    if let k = shortcut("voiceToggleShortcut") { return (k, (varint("voiceToggleShortcut_tapCount") ?? 1) >= 2 ? "doubleTap" : "tap") }
    return nil
}
func weTypeVoiceKey() -> KeySpec? { weTypeVoice()?.key }

// Voice apps with their own global hotkey: no input-source switch, Hijack just presses their key.
// In the config, voiceInput "app:<bundle id>"; their key is detected from their settings when we know how.
struct VoiceApp { let bundle: String; let name: String; let detect: () -> KeySpec? }
let voiceApps: [VoiceApp] = [
    VoiceApp(bundle: "com.pais.handy", name: "Handy", detect: handyVoiceKey),
]

// Handy: settings_store.json, bindings.transcribe.current_binding like "option_left+space".
func handyVoiceKey() -> KeySpec? {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.pais.handy/settings_store.json")
    guard let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let settings = root["settings"] as? [String: Any] ?? root
    guard let binding = ((settings["bindings"] as? [String: Any])?["transcribe"] as? [String: Any])?["current_binding"] as? String
    else { return nil }
    return KeySpec(binding: binding)
}

// Voice input methods we know: their voice key when it can't be read from settings, and helper apps
// that own the voice UI (Sogou dictates in a separate "voice assistant" process).
struct KnownIME { let bundle: String; let sourceID: String; let defaultKey: String?; let helpers: [String] }
let knownIMEs: [KnownIME] = [
    KnownIME(bundle: "com.tencent.inputmethod.wetype", sourceID: "com.tencent.inputmethod.wetype.pinyin", defaultKey: nil, helpers: []),   // detected from its settings
    KnownIME(bundle: "com.sogou.inputmethod.sogou", sourceID: "com.sogou.inputmethod.sogou.pinyin", defaultKey: "left_option", helpers: ["com.sogou.voiceassistant"]),
    KnownIME(bundle: "com.bytedance.inputmethod.doubaoime", sourceID: "com.bytedance.inputmethod.doubaoime.pinyin", defaultKey: "fn", helpers: []),
]
func knownIME(_ sourceID: String) -> KnownIME? {
    guard let bundle = source(sourceID).flatMap({ prop($0, kTISPropertyBundleID) }) else { return nil }
    return knownIMEs.first { $0.bundle == bundle }
}

// MARK: input sources

func currentID() -> String? {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

func source(_ id: String) -> TISInputSource? {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    return (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource])?.first
}
func prop(_ src: TISInputSource, _ key: CFString) -> String? {
    guard let raw = TISGetInputSourceProperty(src, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}
func sourceName(_ id: String) -> String { source(id).flatMap { prop($0, kTISPropertyLocalizedName) } ?? id }
// Enabled, selectable input methods (not plain keyboard layouts) — candidates for the voice source.
func voiceCandidates() -> [(id: String, name: String)] {
    let all = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] ?? []
    return all.compactMap { src in
        guard let id = prop(src, kTISPropertyInputSourceID),
              prop(src, kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String),
              prop(src, kTISPropertyInputSourceType) != (kTISTypeKeyboardLayout as String),
              let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsSelectCapable),
              CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()) else { return nil }
        return (id, prop(src, kTISPropertyLocalizedName) ?? id)
    }
}

func select(_ id: String) -> Bool {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
          let src = list.first else { return false }
    return TISSelectInputSource(src) == noErr
}

// Select and confirm: re-read the current source a moment later and retry once if it didn't stick.
func switchTo(_ id: String, _ label: String) {
    let ok = select(id)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        if currentID() == id { log("\(label) \(id) ok=\(ok)") }
        else { log("\(label) \(id) didn't stick, retry ok=\(select(id))") }
    }
}

// A voice input method (WeType: its capsule) keeps a window on screen until the dictated text is
// finally committed (rough text first, then the tidied version). Switching away before that drops the
// uncommitted text, so that window disappearing is the "done" signal. Owner/bounds need no Screen
// Recording. nil = the input method's process isn't running.
func voiceWindowVisible(_ sourceID: String) -> Bool? {
    guard let bundle = source(sourceID).flatMap({ prop($0, kTISPropertyBundleID) }) else { return nil }
    let owners = Set([bundle] + (knownIME(sourceID)?.helpers ?? []))
    let pids = Set(NSWorkspace.shared.runningApplications.filter { owners.contains($0.bundleIdentifier ?? "") }.map(\.processIdentifier))
    guard !pids.isEmpty else { return nil }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.contains { pids.contains(($0[kCGWindowOwnerPID as String] as? Int32) ?? -1) }
}

// What has keyboard focus right now (app + control role) — for diagnosing focus changes in the logs.
func focusDesc() -> String {
    let sys = AXUIElementCreateSystemWide()
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &ref) == .success, let ref else {
        return "focus=none(\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))"
    }
    let el = ref as! AXUIElement
    var pid: pid_t = 0; AXUIElementGetPid(el, &pid)
    var role: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
    let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid\(pid)"
    return "focus=\(app):\((role as? String) ?? "?")"
}

// MARK: log  (~/Library/Logs/Hijack.log)

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(appName).log")
func log(_ msg: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
    let line = "\(f.string(from: Date())) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}

// MARK: settings — ~/.config/hijack/config.json is the source of truth; the menu just edits it.
// Re-read whenever it changes on disk, so hand edits apply on the next key press or menu open.

let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/hijack/config.json")

final class Config {
    static let shared = Config()
    var trigger: KeySpec?          // nil = "follow" the voice key
    var voiceInput = weTypeID
    var voiceKeys: [String: KeySpec] = [:]   // per voice input; missing = "auto" (detected, or a known default)
    var triggerMode = "hold"                 // "hold": hold to talk · "toggle": tap to start, tap again to stop
    var stopOnAnyKey = true                  // toggle: any key also stops (that key is swallowed, never typed)
    var voiceStyles: [String: String] = [:]  // per voice input: how it wants its key — "hold" | "tap" | "doubleTap"
    var showMenuBarIcon = true
    var language = "system"
    var holdDelay = 0.2            // minimum hold before the voice method gets its key
    var restoreTimeout = 5.0       // longest wait after release before switching back
    var fallbackDelay = 2.5        // used when the voice method shows no window to watch
    private var loadedAt: Date?
    private var checkedAt = Date.distantPast

    init() { reload(force: true) }

    func reload(force: Bool = false) {
        guard force || Date().timeIntervalSince(checkedAt) > 0.5 else { return }   // at most twice a second
        checkedAt = Date()
        let mtime = (try? FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate]) as? Date
        guard force || mtime != loadedAt else { return }
        guard let mtime, let data = try? Data(contentsOf: configURL),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if mtime == nil { migrateFromDefaults(); save() } else { log("config: can't parse \(configURL.path), keeping previous values") }
            loadedAt = mtime; return
        }
        loadedAt = mtime
        trigger = (d["trigger"] as? String) == "follow" || d["trigger"] == nil ? nil : KeySpec(json: d["trigger"])
        voiceInput = d["voiceInput"] as? String ?? weTypeID
        voiceKeys = [:]
        for (id, v) in d["voiceKeys"] as? [String: Any] ?? [:] {
            if let k = KeySpec(json: v) { voiceKeys[id] = k } else if (v as? String) != "auto" { log("config: unknown voiceKeys[\(id)] \(v)") }
        }
        if let old = KeySpec(json: d["voiceKey"]), voiceKeys[voiceInput] == nil { voiceKeys[voiceInput] = old }   // older single "voiceKey"
        showMenuBarIcon = d["showMenuBarIcon"] as? Bool ?? true
        triggerMode = (d["triggerMode"] as? String) == "toggle" ? "toggle" : "hold"
        stopOnAnyKey = d["stopOnAnyKey"] as? Bool ?? true
        voiceStyles = (d["voiceStyles"] as? [String: String] ?? [:]).filter { ["hold", "tap", "doubleTap"].contains($0.value) }
        language = d["language"] as? String ?? "system"
        holdDelay = d["holdDelay"] as? Double ?? 0.2
        restoreTimeout = d["restoreTimeout"] as? Double ?? 5.0
        fallbackDelay = d["fallbackDelay"] as? Double ?? 2.5
        if !force { log("config: reloaded (trigger \(trigger?.name ?? "follow"), voiceInput \(voiceInput), voiceKeys \(voiceKeys.mapValues(\.name)))") }
        if d["trigger"] != nil, (d["trigger"] as? String) != "follow", trigger == nil { log("config: unknown trigger \(d["trigger"]!), following the voice key") }
    }

    func save() {
        func j(_ v: Any) -> String {
            if let s = v as? String { return "\"\(s)\"" }
            if let b = v as? Bool { return b ? "true" : "false" }
            if let x = v as? Double { return String(format: "%g", x) }
            let d = (try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
            return String(data: d, encoding: .utf8) ?? "null"
        }
        let pairs: [(String, Any)] = [
            ("trigger", trigger?.json ?? "follow"), ("voiceInput", voiceInput), ("voiceKeys", voiceKeys.mapValues(\.json)),
            ("triggerMode", triggerMode), ("stopOnAnyKey", stopOnAnyKey), ("voiceStyles", voiceStyles),
            ("showMenuBarIcon", showMenuBarIcon), ("language", language),
            ("holdDelay", holdDelay), ("restoreTimeout", restoreTimeout), ("fallbackDelay", fallbackDelay),
        ]
        let text = "{\n" + pairs.map { "  \"\($0.0)\": \(j($0.1))" }.joined(separator: ",\n") + "\n}\n"
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: configURL, atomically: true, encoding: .utf8)
        loadedAt = (try? FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate]) as? Date
    }

    // One-time: carry over settings from the menu-only versions (UserDefaults).
    private func migrateFromDefaults() {
        let u = UserDefaults.standard
        voiceInput = u.string(forKey: "voiceInputSource") ?? weTypeID
        trigger = (u.object(forKey: "triggerKey") as? Int).map { KeySpec(code: $0) }
        if let k = (u.object(forKey: "voiceKey.\(voiceInput)") as? Int).map({ KeySpec(code: $0) }) { voiceKeys[voiceInput] = k }
        showMenuBarIcon = u.object(forKey: "showMenuBarIcon") as? Bool ?? true
        language = u.string(forKey: "language") ?? "system"
        log("config: created \(configURL.path)")
    }
}

final class Model {
    static let shared = Model()
    var c: Config { Config.shared.reload(); return Config.shared }

    var voiceID: String { c.voiceInput }
    var app: VoiceApp? { voiceID.hasPrefix("app:") ? voiceApps.first { "app:" + $0.bundle == voiceID } : nil }
    var isApp: Bool { voiceID.hasPrefix("app:") }
    var voiceName: String { app?.name ?? (isApp ? String(voiceID.dropFirst(4)) : sourceName(voiceID)) }
    var isWeType: Bool { voiceID == weTypeID }
    // Voice key precedence: the user's explicit choice, else auto-detected (WeType only), else Right Option.
    var userVoiceKey: KeySpec? { c.voiceKeys[voiceID] }
    var detectedVoiceKey: KeySpec? {
        if isWeType { return weTypeVoiceKey() }
        if let app { return app.detect() }
        return knownIME(voiceID)?.defaultKey.flatMap(KeySpec.named)
    }
    var forwardKey: KeySpec { userVoiceKey ?? detectedVoiceKey ?? KeySpec.named("right_option")! }
    // Trigger precedence: the user's explicit choice, else follow the voice key.
    var customTrigger: KeySpec? { c.trigger }
    var trigger: KeySpec { customTrigger ?? forwardKey }
    var toggleMode: Bool { c.triggerMode == "toggle" }
    var detectedStyle: String? { isWeType ? weTypeVoice()?.style : nil }
    var voiceStyle: String { c.voiceStyles[voiceID] ?? detectedStyle ?? "hold" }
}

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

// MARK: menu (the whole UI)

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = Engine()
    let m = Model.shared
    let menu = NSMenu()
    var item: NSStatusItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self
        updateIcon()
        engine.start()
        if !AXIsProcessTrusted() {   // system prompt also adds us to the Accessibility list
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
    }

    // Opening the app again (Finder / Spotlight / LaunchBar) pops the menu at the pointer,
    // so it stays reachable with the menu bar icon hidden.
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return false
    }

    func updateIcon() {
        if Config.shared.showMenuBarIcon, item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let icon = Bundle.main.image(forResource: "HijackMenuTemplate")
                ?? NSImage(systemSymbolName: "mic", accessibilityDescription: appName)
            icon?.isTemplate = true                  // follows light/dark menu bar
            icon?.size = NSSize(width: 18, height: 18)
            it.button?.image = icon
            it.menu = menu
            item = it
        } else if !Config.shared.showMenuBarIcon, let it = item {
            NSStatusBar.system.removeStatusItem(it); item = nil
        }
    }

    // Rebuilt every time it opens, so it always shows the live state.
    // Rebuilt every time it opens, so it always shows the live state.
    // Layout: status · how you dictate (mode, shortcut) · dictation source (+ its key, its start style) · app.
    func menuNeedsUpdate(_ menu: NSMenu) {
        Config.shared.reload()
        menu.removeAllItems()
        @discardableResult
        func add(_ title: String, _ action: Selector? = nil, on: Bool = false, to: NSMenu? = nil, value: String? = nil, indent: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self; i.state = on ? .on : .off; i.representedObject = value; i.indentationLevel = indent
            (to ?? menu).addItem(i); return i
        }
        func header(_ title: String, to: NSMenu? = nil) {
            if #available(macOS 14.0, *) { (to ?? menu).addItem(NSMenuItem.sectionHeader(title: title)) }
            else { add(title, to: to) }
        }
        let c = m.c, name = m.voiceName, key = m.trigger.name

        // Status — derived from the same state the engine uses.
        if !AXIsProcessTrusted() {
            add(L("⚠︎ 需要辅助功能权限，点这里去允许…", "⚠︎ Needs Accessibility permission — Allow…"), #selector(openAccessibility))
        } else if m.toggleMode {
            add(L("点按 \(key) 用\(name)听写，再点停止", "Tap \(key) to dictate with \(name), tap again to stop"))
        } else {
            add(L("按住 \(key) 用\(name)听写", "Hold \(key) to dictate with \(name)"))
        }
        let readable = m.isWeType || m.app != nil
        if m.userVoiceKey == nil && (m.detectedVoiceKey == nil || !readable) {
            add(m.detectedVoiceKey.map { L("⚠︎ \(name)里的语音键用的是默认值 \($0.name)，请确认一致", "⚠︎ \(name)'s voice key is assumed to be \($0.name) — make sure it matches") }
                ?? L("⚠︎ 读不到\(name)里的语音键，请在「语音来源」里选", "⚠︎ Can't detect \(name)'s voice key — pick it under Dictation Source"))
        }
        menu.addItem(.separator())

        // How you dictate
        header(L("听写方式", "How You Dictate"))
        add(L("按住说话", "Hold to Talk"), #selector(setTriggerMode(_:)), on: !m.toggleMode, value: "hold")
        add(L("点按开始，再点停止（免按）", "Tap to Start, Tap to Stop"), #selector(setTriggerMode(_:)), on: m.toggleMode, value: "toggle")
        if m.toggleMode {
            add(L("按任意键也可停止", "Any Key Also Stops"), #selector(toggleStopOnAnyKey), on: c.stopOnAnyKey, indent: 1)
        }
        let keys = NSMenu()
        add(L("同\(name)里的语音键（\(m.forwardKey.name)）", "Same as \(name)'s Voice Key (\(m.forwardKey.name))"), #selector(setTrigger(_:)), on: m.customTrigger == nil, to: keys, value: "auto")
        keys.addItem(.separator())
        for id in quickKeys { let k = KeySpec.named(id)!; add(k.name, #selector(setTrigger(_:)), on: m.customTrigger == k, to: keys, value: id) }
        if let t = m.customTrigger, t.quickID.map(quickKeys.contains) != true { add(t.name, on: true, to: keys) }
        keys.addItem(.separator())
        add(L("其他按键…", "Other Key…"), #selector(openConfig), to: keys)
        add(L("快捷键：\(key)", "Shortcut: \(key)")).submenu = keys
        menu.addItem(.separator())

        // Dictation source — only voice tools that are installed; its key and start style live here too.
        let src = NSMenu()
        var listed = Set<String>()
        for ime in knownIMEs where source(ime.sourceID) != nil {
            add(sourceName(ime.sourceID), #selector(setVoiceSource(_:)), on: m.voiceID == ime.sourceID, to: src, value: ime.sourceID)
            listed.insert(ime.sourceID)
        }
        for a in voiceApps where NSWorkspace.shared.urlForApplication(withBundleIdentifier: a.bundle) != nil {
            add(a.name, #selector(setVoiceSource(_:)), on: m.voiceID == "app:" + a.bundle, to: src, value: "app:" + a.bundle)
            listed.insert("app:" + a.bundle)
        }
        if !listed.contains(m.voiceID) { add(L("\(name)（设置文件）", "\(name) (config file)"), on: true, to: src) }
        src.addItem(.separator())
        header(L("\(name)里的语音键", "\(name)'s Voice Key"), to: src)
        let found = m.detectedVoiceKey
        let autoTitle: String = {
            guard let k = found else { return L("自动检测（没读到）", "Auto-Detect (Not Found)") }
            return readable ? L("\(k.name)（自动检测）", "\(k.name) (Detected)") : L("\(k.name)（默认，未验证）", "\(k.name) (Default, Unverified)")
        }()
        add(autoTitle, #selector(setVoiceKey(_:)), on: m.userVoiceKey == nil, to: src, value: "auto")
        for id in quickKeys where KeySpec.named(id) != found {
            let k = KeySpec.named(id)!; add(k.name, #selector(setVoiceKey(_:)), on: m.userVoiceKey == k, to: src, value: id)
        }
        if let u = m.userVoiceKey, u.quickID.map(quickKeys.contains) != true { add(u.name, on: true, to: src) }
        add(L("其他…", "Other…"), #selector(openConfig), to: src)
        // Start style: only when the source can't simply be held (or the user changed it).
        if m.voiceStyle != "hold" || c.voiceStyles[m.voiceID] != nil {
            src.addItem(.separator())
            header(L("\(name)的启动方式", "\(name) Starts Listening On"), to: src)
            let names = ["hold": L("按住", "Hold"), "tap": L("单击", "Single Tap"), "doubleTap": L("双击", "Double Tap")]
            for code in ["hold", "tap", "doubleTap"] {
                add(names[code]!, #selector(setVoiceStyle(_:)), on: m.voiceStyle == code, to: src, value: code)
            }
        }
        add(L("语音来源：\(name)", "Dictation Source: \(name)")).submenu = src
        menu.addItem(.separator())

        // App
        add(L("开机启动", "Open at Login"), #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        add(L("在菜单栏显示图标", "Show in Menu Bar"), #selector(toggleIcon), on: c.showMenuBarIcon)
        let langs = NSMenu()
        for (code, title) in [("system", L("跟随系统", "System")), ("en", "English"), ("zh", "中文")] {
            add(title, #selector(setLanguage(_:)), on: c.language == code, to: langs, value: code)
        }
        add(L("语言", "Language")).submenu = langs
        let edit = add(L("编辑配置文件…", "Edit Config File…"), #selector(openConfig))
        edit.keyEquivalent = ","; edit.keyEquivalentModifierMask = .command
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("退出 \(appName)", "Quit \(appName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // Menu actions edit the config file (the source of truth).
    func pick(_ sender: NSMenuItem) -> KeySpec? {
        (sender.representedObject as? String).flatMap { $0 == "auto" ? nil : KeySpec.named($0) }
    }
    @objc func setTrigger(_ sender: NSMenuItem) {
        let c = Config.shared; c.reload(); c.trigger = pick(sender); c.save()
        log("trigger set to \(m.trigger.name)")
    }
    @objc func setVoiceKey(_ sender: NSMenuItem) {
        let c = Config.shared; c.reload(); c.voiceKeys[c.voiceInput] = pick(sender); c.save()
        log("voice key set to \(m.forwardKey.name)")
    }
    @objc func setTriggerMode(_ sender: NSMenuItem) {
        let c = Config.shared; c.reload(); c.triggerMode = sender.representedObject as? String ?? "hold"; c.save()
        log("trigger mode set to \(c.triggerMode)")
    }
    @objc func toggleStopOnAnyKey() {
        let c = Config.shared; c.reload(); c.stopOnAnyKey.toggle(); c.save()
    }
    @objc func setVoiceStyle(_ sender: NSMenuItem) {
        let c = Config.shared; c.reload()
        let v = sender.representedObject as? String
        c.voiceStyles[c.voiceInput] = v == "auto" ? nil : v; c.save()
        log("voice style for \(c.voiceInput) set to \(m.voiceStyle)")
    }
    @objc func setVoiceSource(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let c = Config.shared; c.reload(); c.voiceInput = id; c.save()
        log("voice source set to \(id)")
    }
    @objc func setLanguage(_ sender: NSMenuItem) {
        let c = Config.shared; c.reload(); c.language = sender.representedObject as? String ?? "system"; c.save()
    }
    @objc func toggleIcon() {
        let c = Config.shared; c.reload(); c.showMenuBarIcon.toggle(); c.save(); updateIcon()
    }
    @objc func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        else { try? SMAppService.mainApp.register() }
    }
    @objc func openConfig() {
        Config.shared.reload()
        if !FileManager.default.fileExists(atPath: configURL.path) { Config.shared.save() }
        NSWorkspace.shared.open(configURL)
    }
    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
