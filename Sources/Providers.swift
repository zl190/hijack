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

// MARK: providers — everything specific to one voice tool lives behind this interface.

/// A voice tool Hijack can drive: an input method (switch to it, press its voice key, switch back)
/// or an app with its own global hotkey (just press that hotkey).
protocol VoiceProvider {
    var id: String { get }                  // value of "voiceInput" in the config
    var name: String { get }
    var isInstalled: Bool { get }
    var switchesInputSource: Bool { get }
    var readsSettings: Bool { get }         // detected() comes from its own settings, not a built-in guess
    func detected() -> (key: KeySpec?, style: String?)
    func isBusy() -> Bool?                  // its voice UI is on screen; nil = can't tell
    func windowReport() -> String           // what isBusy() saw, for the log when no window showed up
}

struct InputMethodProvider: VoiceProvider {
    let sourceID: String
    var label: (zh: String, en: String)? = nil   // our own names; the system often only registers a Chinese one
    var defaultKey: String? = nil           // when its settings can't be read
    var helpers: [String] = []              // apps that own its voice UI (Sogou: a separate voice assistant)
    var reader: (() -> (key: KeySpec, style: String)?)? = nil

    var id: String { sourceID }
    var name: String { label.map { L($0.zh, $0.en) } ?? sourceName(sourceID) }
    var isInstalled: Bool { source(sourceID) != nil }
    var switchesInputSource: Bool { true }
    var readsSettings: Bool { reader != nil }
    func detected() -> (key: KeySpec?, style: String?) {
        if let reader { let r = reader(); return (r?.key, r?.style) }
        return (defaultKey.flatMap(KeySpec.named), nil)
    }
    // Its voice window stays up until the dictated text is finally committed (rough text first, then the
    // tidied version); switching away earlier drops the uncommitted text. Owner/bounds need no Screen Recording.
    func isBusy() -> Bool? {
        guard let bundle = source(sourceID).flatMap({ prop($0, kTISPropertyBundleID) }) else { return nil }
        let owners = Set([bundle] + helpers)
        let pids = Set(NSWorkspace.shared.runningApplications.filter { owners.contains($0.bundleIdentifier ?? "") }.map(\.processIdentifier))
        guard !pids.isEmpty else { return nil }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { pids.contains(($0[kCGWindowOwnerPID as String] as? Int32) ?? -1) }
    }
    func windowReport() -> String {
        guard let bundle = source(sourceID).flatMap({ prop($0, kTISPropertyBundleID) }) else { return "no bundle id for \(sourceID)" }
        let owners = Set([bundle] + helpers)
        let pids = NSWorkspace.shared.runningApplications.filter { owners.contains($0.bundleIdentifier ?? "") }.map(\.processIdentifier)
        guard !pids.isEmpty else { return "no running process for \(owners.sorted().joined(separator: ","))" }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let mine = list.filter { pids.contains(($0[kCGWindowOwnerPID as String] as? Int32) ?? -1) }.count
        return "pids \(pids.map(String.init).joined(separator: ",")) have \(mine) on-screen windows (of \(list.count))"
    }
}

struct AppProvider: VoiceProvider {
    let bundle: String
    var appName: String? = nil
    var reader: (() -> KeySpec?)? = nil

    var id: String { "app:" + bundle }
    var name: String {
        appName ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundle
    }
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil }
    var switchesInputSource: Bool { false }
    var readsSettings: Bool { reader != nil }
    func detected() -> (key: KeySpec?, style: String?) { (reader?(), nil) }
    func isBusy() -> Bool? { nil }
    func windowReport() -> String { "an app: its window isn't watched" }
}

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

// The voice tools Hijack knows. Order = menu order. Adding one is adding a line here.
let builtInProviders: [VoiceProvider] = [
    InputMethodProvider(sourceID: weTypeID, label: ("微信输入法", "WeType"), reader: weTypeVoice),
    InputMethodProvider(sourceID: "com.sogou.inputmethod.sogou.pinyin", label: ("搜狗输入法", "Sogou"), defaultKey: "left_option", helpers: ["com.sogou.voiceassistant"]),
    InputMethodProvider(sourceID: "com.bytedance.inputmethod.doubaoime.pinyin", label: ("豆包输入法", "Doubao"), defaultKey: "fn"),
    AppProvider(bundle: "com.pais.handy", appName: "Handy", reader: handyVoiceKey),
]

/// The provider for a config value; unknown ones get a generic input method or app.
func voiceProvider(for id: String) -> VoiceProvider {
    if let p = builtInProviders.first(where: { $0.id == id }) { return p }
    return id.hasPrefix("app:") ? AppProvider(bundle: String(id.dropFirst(4))) : InputMethodProvider(sourceID: id)
}
func installedProviders() -> [VoiceProvider] { builtInProviders.filter(\.isInstalled) }
