import HijackCore
import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

// MARK: settings — ~/.config/hijack/config.json is the source of truth; the menu just edits it.
// Re-read whenever it changes on disk, so hand edits apply on the next key press or menu open.

let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/hijack/config.json")

final class Config {
    static let shared: Config = Config()
    var trigger: KeySpec?  // nil = "follow" the voice key
    var voiceInput: String = weTypeID
    var voiceKeys: [String: KeySpec] = [:]  // per voice input; missing = "auto" (detected, or a known default)
    var triggerMode: String = "hold"  // "hold": hold to talk · "toggle": tap to start, tap again to stop
    var stopOnAnyKey: Bool = true  // toggle: any key also stops (that key is swallowed, never typed)
    var voiceStyles: [String: String] = [:]  // per voice input: how it wants its key — "hold" | "tap" | "doubleTap"
    var showMenuBarIcon: Bool = true
    var showDockIcon: Bool = false
    var lastError: String?  // why the file couldn't be read (a code; see errorText); previous values stay in effect
    // Localized at display time: the language setting lives in this object, so it can't be read while loading.
    var errorText: String? {
        lastError.map { _ in L("配置文件不是有效的 JSON，正在沿用上一次的设置", "The config file isn't valid JSON; keeping the previous settings") }
    }
    var language: String = "system"
    var holdDelay: Double = 0.2  // minimum hold before the voice method gets its key
    var restoreTimeout: Double = 5.0  // longest wait after release before switching back
    var fallbackDelay: Double = 2.5  // used when the voice method shows no window to watch
    private var loadedAt: Date?
    private var checkedAt: Date = .distantPast

    init() { reload(force: true) }

    func reload(force: Bool = false) {
        guard force || Date().timeIntervalSince(checkedAt) > 0.5 else { return }  // at most twice a second
        checkedAt = Date()
        let mtime = (try? FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate]) as? Date
        guard force || mtime != loadedAt else { return }
        guard let mtime, let data = try? Data(contentsOf: configURL),
            let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            if mtime == nil {
                migrateFromDefaults(); save()
            } else {
                lastError = "invalidJSON"; log("config: can't parse \(configURL.path), keeping previous values")
            }
            loadedAt = mtime; return
        }
        loadedAt = mtime
        lastError = nil
        trigger = (d["trigger"] as? String) == "follow" || d["trigger"] == nil ? nil : KeySpec(json: d["trigger"])
        voiceInput = d["voiceInput"] as? String ?? weTypeID
        voiceKeys = [:]
        for (id, v) in d["voiceKeys"] as? [String: Any] ?? [:] {
            if let k = KeySpec(json: v) {
                voiceKeys[id] = k
            } else if (v as? String) != "auto" {
                log("config: unknown voiceKeys[\(id)] \(v)")
            }
        }
        if let old = KeySpec(json: d["voiceKey"]), voiceKeys[voiceInput] == nil { voiceKeys[voiceInput] = old }  // older single "voiceKey"
        showMenuBarIcon = d["showMenuBarIcon"] as? Bool ?? true
        showDockIcon = d["showDockIcon"] as? Bool ?? false
        triggerMode = (d["triggerMode"] as? String) == "toggle" ? "toggle" : "hold"
        stopOnAnyKey = d["stopOnAnyKey"] as? Bool ?? true
        voiceStyles = (d["voiceStyles"] as? [String: String] ?? [:]).filter { ["hold", "tap", "doubleTap"].contains($0.value) }
        language = d["language"] as? String ?? "system"
        // review-5 #14: a hand edit bypasses `hijack set`'s own range check, so loading clamps too.
        func timing(_ key: String, default def: Double, range: ClosedRange<Double>, name: String) -> Double {
            let (v, logLine) = clampedTiming(d[key] as? Double ?? def, to: range, name: name)
            if let logLine { log(logLine) }
            return v
        }
        holdDelay = timing("holdDelay", default: 0.2, range: holdDelayRange, name: "holdDelay")
        restoreTimeout = timing("restoreTimeout", default: 5.0, range: restoreTimeoutRange, name: "restoreTimeout")
        fallbackDelay = timing("fallbackDelay", default: 2.5, range: fallbackDelayRange, name: "fallbackDelay")
        if !force {
            log(
                "config: reloaded (trigger \(trigger?.name ?? "follow"), voiceInput \(voiceInput), voiceKeys \(voiceKeys.mapValues(\.name)))"
            )
        }
        if let rawTrigger = d["trigger"], (rawTrigger as? String) != "follow", trigger == nil {
            log("config: unknown trigger \(rawTrigger), following the voice key")
        }
    }

    func save() {
        // A hand edit that doesn't parse yet must not be overwritten with the old values: refuse to write.
        if lastError != nil, FileManager.default.fileExists(atPath: configURL.path) {
            log("config: not saving — \(configURL.path) has an error; fix or revert it first")
            NSSound.beep()
            return
        }
        // review-5 #14: jsonLiteral (Sources/Core/ConfigValues.swift) escapes through JSONSerialization,
        // so a value with a quote in it (hijack set source 'a"b') no longer writes invalid JSON.
        let pairs: [(String, Any)] = [
            ("trigger", trigger?.json ?? "follow"), ("voiceInput", voiceInput), ("voiceKeys", voiceKeys.mapValues(\.json)),
            ("triggerMode", triggerMode), ("stopOnAnyKey", stopOnAnyKey), ("voiceStyles", voiceStyles),
            ("showMenuBarIcon", showMenuBarIcon), ("showDockIcon", showDockIcon), ("language", language),
            ("holdDelay", holdDelay), ("restoreTimeout", restoreTimeout), ("fallbackDelay", fallbackDelay),
        ]
        let text = "{\n" + pairs.map { "  \"\($0.0)\": \(jsonLiteral($0.1))" }.joined(separator: ",\n") + "\n}\n"
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
    static let shared: Model = Model()
    var c: Config { Config.shared.reload(); return Config.shared }

    var voiceID: String { c.voiceInput }
    var provider: VoiceProvider { voiceProvider(for: voiceID) }
    var voiceName: String { provider.name }
    // Voice key precedence: the user's explicit choice, else what the provider detects (or its default).
    var userVoiceKey: KeySpec? { c.voiceKeys[voiceID] }
    var detectedVoiceKey: KeySpec? { provider.detected().key }
    // "right_option" is a literal id in namedKeys (quickKeys); see KeysTests.testW5_QuickKeysAlwaysResolveToANamedKey.
    // swift-format-ignore: NeverForceUnwrap
    var forwardKey: KeySpec { userVoiceKey ?? detectedVoiceKey ?? KeySpec.named("right_option")! }
    // Trigger precedence: the user's explicit choice, else follow the voice key.
    var customTrigger: KeySpec? { c.trigger }
    var trigger: KeySpec { customTrigger ?? forwardKey }
    var toggleMode: Bool { c.triggerMode == "toggle" }
    var detectedStyle: String? { provider.detected().style }
    var voiceStyle: String { c.voiceStyles[voiceID] ?? detectedStyle ?? "hold" }
}
