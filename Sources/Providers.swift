import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

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
