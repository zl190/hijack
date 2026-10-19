import HijackCore
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
let weTypeSettingsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/WeType/mmkv/wetype.settings")
func weTypeVoice() -> (key: KeySpec, style: String)? {
    let url = weTypeSettingsURL
    guard let data = try? Data(contentsOf: url), data.count > 4 else { return nil }
    let live = Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
    guard live > 0, 4 + live <= data.count,
        let s = String(data: data.subdata(in: 4..<(4 + live)), encoding: .isoLatin1)
    else { return nil }
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
    var id: String { get }  // value of "voiceInput" in the config
    var name: String { get }
    var isInstalled: Bool { get }
    var switchesInputSource: Bool { get }
    var readsSettings: Bool { get }  // detected() comes from its own settings, not a built-in guess
    func detected() -> (key: KeySpec?, style: String?)
    func processIDs() -> [pid_t]  // its running processes (for its windows and its microphone use)
    func windowState() -> WindowState  // is its voice UI on screen
    /// The installed version, when its bundle can be found (ADR 0025: `triggerMode: "auto"` reads it).
    var installedVersion: String? { get }
    /// It starts on its own physical talk key and ignores a posted one (WeType from 3.0): auto mode then follows
    /// instead of posting. Decided from `installedVersion`, never from the key event stream (docs/adr/0025).
    var takesTalkKeyItself: Bool { get }
}
extension VoiceProvider {
    var installedVersion: String? { nil }
    var takesTalkKeyItself: Bool { false }
}

/// On-screen windows owned by these processes. Thread-safe (no input-source calls), for sampling off the main thread.
func onScreenWindows(of pids: [pid_t]) -> WindowState {
    guard !pids.isEmpty else { return .unknown("not running") }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let n = list.filter { pids.contains(($0[kCGWindowOwnerPID as String] as? Int32) ?? -1) }.count
    return n > 0 ? .visible(n) : .none("no window (pid \(pids.map(String.init).joined(separator: ",")))")
}
extension VoiceProvider {
    func isBusy() -> Bool? { windowState().busy }
}

/// Info.plist reads for `installedVersion`, keyed by plist path and invalidated by its modification date.
struct VersionCacheEntry {
    let modified: Date, bundleID: String, version: String?
}
final class VersionCache: @unchecked Sendable {
    let lock = NSLock()
    var entries: [String: VersionCacheEntry] = [:]
}
let versionCache = VersionCache()

struct InputMethodProvider: VoiceProvider {
    let sourceID: String
    var label: (zh: String, en: String)? = nil  // our own names; the system often only registers a Chinese one
    var defaultKey: String? = nil  // when its settings can't be read
    var helpers: [String] = []  // apps that own its voice UI (Sogou: a separate voice assistant)
    var reader: (() -> (key: KeySpec, style: String)?)? = nil
    var bundleID: String? = nil  // the input method app, for its version (Info.plist); nil = version unknown
    var takesTalkKeyFrom: ((String?) -> Bool)? = nil  // version → takes its talk key itself (ADR 0025)

    var id: String { sourceID }
    var name: String { label.map { L($0.zh, $0.en) } ?? sourceName(sourceID) }
    var isInstalled: Bool { source(sourceID) != nil }
    var switchesInputSource: Bool { true }
    var readsSettings: Bool { reader != nil }
    /// CFBundleShortVersionString of the input method's app bundle, off the tap path (Model is only consulted from
    /// refresh(), the menu, Settings and the CLI). Review 0025 M2: not through `Bundle(url:)`, which caches the Info.plist
    /// it first read for the process lifetime and would keep 2.2.3 across WeType's in-place upgrade to 3.0; the plist
    /// is read straight from disk, once per modification date (`versionCache`), so a menu open costs one stat.
    /// Found through LaunchServices first, then the two input method folders (a Mac whose LaunchServices database
    /// lacks the input method would otherwise read "unknown" and auto would fall to hold).
    var installedVersion: String? {
        guard let bundleID else { return nil }
        let folders = ["/Library/Input Methods", NSHomeDirectory() + "/Library/Input Methods"]
        var candidates = [NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)].compactMap { $0 }
        for folder in folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".app") {
                candidates.append(URL(fileURLWithPath: folder).appendingPathComponent(name))
            }
        }
        for url in candidates {
            let plist = url.appendingPathComponent("Contents/Info.plist")
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: plist.path))?[.modificationDate] as? Date
            else { continue }
            if let hit = versionCache.lock.withLock({ versionCache.entries[plist.path] }), hit.modified == modified {
                if hit.bundleID == bundleID { return hit.version } else { continue }
            }
            guard let info = NSDictionary(contentsOf: plist) else { continue }
            let entry = VersionCacheEntry(
                modified: modified, bundleID: info["CFBundleIdentifier"] as? String ?? "",
                version: info["CFBundleShortVersionString"] as? String)
            versionCache.lock.withLock { versionCache.entries[plist.path] = entry }
            if entry.bundleID == bundleID { return entry.version }
        }
        return nil
    }
    var takesTalkKeyItself: Bool { takesTalkKeyFrom?(installedVersion) ?? false }
    func detected() -> (key: KeySpec?, style: String?) {
        if let reader { let r = reader(); return (r?.key, r?.style) }
        return (defaultKey.flatMap(KeySpec.named), nil)
    }
    // Its voice window stays up until the dictated text is finally committed (rough text first, then the
    // tidied version); switching away earlier drops the uncommitted text. Owner/bounds need no Screen Recording.
    func processIDs() -> [pid_t] {
        guard let bundle = source(sourceID).flatMap({ prop($0, kTISPropertyBundleID) }) else { return [] }
        let owners = Set([bundle] + helpers)
        return NSWorkspace.shared.runningApplications.filter { owners.contains($0.bundleIdentifier ?? "") }.map(\.processIdentifier)
    }
    func windowState() -> WindowState {
        guard source(sourceID).flatMap({ prop($0, kTISPropertyBundleID) }) != nil else { return .unknown("no bundle id for \(sourceID)") }
        return onScreenWindows(of: processIDs())
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
    func processIDs() -> [pid_t] { NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map(\.processIdentifier) }
    func windowState() -> WindowState { .unknown("an app: its window isn't watched") }
}

// Handy: settings_store.json, bindings.transcribe.current_binding like "option_left+space".
let handySettingsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/com.pais.handy/settings_store.json")
func handyVoiceKey() -> KeySpec? {
    let url = handySettingsURL
    guard let data = try? Data(contentsOf: url),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let settings = root["settings"] as? [String: Any] ?? root
    guard let binding = ((settings["bindings"] as? [String: Any])?["transcribe"] as? [String: Any])?["current_binding"] as? String
    else { return nil }
    return KeySpec(binding: binding)
}

// The voice tools Hijack knows. Order = menu order. Adding one is adding a line here.
let builtInProviders: [VoiceProvider] = [
    InputMethodProvider(
        sourceID: weTypeID, label: ("微信输入法", "WeType"), reader: weTypeVoice, bundleID: "com.tencent.inputmethod.wetype",
        takesTalkKeyFrom: DictationMode.weTypeTakesTalkKey),
    InputMethodProvider(
        sourceID: "com.sogou.inputmethod.sogou.pinyin", label: ("搜狗输入法", "Sogou"), defaultKey: "left_option",
        helpers: ["com.sogou.voiceassistant"]),
    InputMethodProvider(sourceID: "com.bytedance.inputmethod.doubaoime.pinyin", label: ("豆包输入法", "Doubao"), defaultKey: "fn"),
    AppProvider(bundle: "com.pais.handy", appName: "Handy", reader: handyVoiceKey),
]

/// The provider for a config value; unknown ones get a generic input method or app.
func voiceProvider(for id: String) -> VoiceProvider {
    if let p = builtInProviders.first(where: { $0.id == id }) { return p }
    return id.hasPrefix("app:") ? AppProvider(bundle: String(id.dropFirst(4))) : InputMethodProvider(sourceID: id)
}
func installedProviders() -> [VoiceProvider] { builtInProviders.filter(\.isInstalled) }

/// Files whose changes can change a talk key (watched by SettingsWatch).
let voiceSettingsFiles: [URL] = [weTypeSettingsURL, handySettingsURL]
