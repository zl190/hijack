import HijackCore
import AppKit
import ApplicationServices

// MARK: command line — the same binary; with a known command as its first argument it runs that and exits.
//   hijack status | doctor | sources | get [setting] | set <setting> <value> | log [-f] [-n N] [--live] | stats | version | help
// --json on status / sources / get / stats, for scripts and agents. Settings go through the same Config as the app,
// so the running app picks changes up on its next key press or menu open.

let cliCommands: Set<String> = ["status", "doctor", "sources", "get", "set", "log", "stats", "version", "help", "--help", "-h"]

/// Runs a CLI command and returns its exit code, or nil when the arguments aren't a CLI call (start the app).
func runCLI(_ args: [String]) -> Int32? {
    guard let cmd = args.first, cliCommands.contains(cmd) else { return nil }
    var rest = Array(args.dropFirst())
    let json = rest.contains("--json"); rest.removeAll { $0 == "--json" }
    switch cmd {
    case "status": return cliStatus(json: json)
    case "doctor": return cliDoctor()
    case "sources": return cliSources(json: json)
    case "get": return cliGet(rest.first, json: json)
    case "set": return cliSet(rest)
    case "log": return cliLog(rest)
    case "stats": return cliStats(rest, json: json)
    case "version": return cliVersion()
    default: print(cliHelp); return 0
    }
}

// Called through a symlink (~/.local/bin/hijack, brew's bin), Bundle.main isn't the app: resolve the real executable.
let appBundle: Bundle = {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buf, &size) == 0 else { return Bundle.main }
    let exe = URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath()
    return Bundle(url: exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) ?? Bundle.main
}()
let appVersion = appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
// HijackCommit (not CFBundleVersion — review-4 M2) carries the build identity build.sh writes: the sha,
// +dirty when built from an unclean tree. CFBundleVersion stays plain VERSION, so Sparkle's comparator
// orders builds by VERSION only (see build.sh for the full rationale).
let appCommit = appBundle.object(forInfoDictionaryKey: "HijackCommit") as? String ?? "unknown"

/// The running version, and the update the app recorded at its last check (no network call).
/// The app writes HijackUpdateFound from its Sparkle delegate; Sparkle stores only the skipped build.
func cliVersion() -> Int32 {
    print("Hijack \(appVersion) (commit \(appCommit))")
    // The CLI is often a symlink outside the bundle, so it reads the app's defaults domain by name.
    let d = UserDefaults.standard.persistentDomain(forName: "com.zl190.hijack") ?? [:]
    let found = UpdateFound(defaults: d[UpdateFound.defaultsKey] as? [String: Any])
    if let line = UpdateNotice.line(running: appVersion, found: found, skippedBuild: d["SUSkippedVersion"] as? String) { print(line) }
    return 0
}

let cliHelp = """
    hijack — hold a key to dictate with another tool's voice input, from any input source

    Usage:
      hijack status [--json]          what Hijack is doing and whether it can
      hijack doctor                   check everything; exits 1 if something is broken
      hijack sources [--json]         installed voice sources and their talk keys
      hijack get [setting] [--json]   read settings
      hijack set <setting> <value>    change a setting (validated)
      hijack log [-f] [-n N]          show the log: one line per dictation, plus errors (-f follows it)
      hijack log --live               watch every step of each dictation as it happens (Ctrl-C to stop)
      hijack stats [--days N|--all] [--json]   how reliable dictation has been (default: last 7 days)
      hijack version                  running version, and the update Sparkle found last

    Settings:
      mode             hold | toggle
      shortcut         follow | a key (right_option, fn, f18, ctrl+option+f18, …)
      any-key-stops    true | false              (toggle mode)
      source           a voice source id or name (see `hijack sources`)
      talk-key         auto | a key              (for the current source)
      style            auto | hold | tap | doubleTap   (how the current source starts)
      menu-bar-icon    true | false
      dock-icon        true | false
      language         system | en | zh
      hold-delay       seconds before the voice tool gets its key
      restore-timeout  longest wait for the text, in seconds
      fallback-delay   wait when the voice tool shows no window, in seconds

    Config file: ~/.config/hijack/config.json
    """

// MARK: helpers

private func fail(_ msg: String) -> Int32 { FileHandle.standardError.write((msg + "\n").data(using: .utf8) ?? Data()); return 1 }

private func printJSON(_ obj: Any) {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
        let s = String(data: d, encoding: .utf8)
    {
        print(s)
    }
}

// MARK: MetricKit (Sources/Metrics.swift writes the files; Sources/Core/MetricsSummary.swift reads them)

/// How many payload files are on disk — `hasPayloads` without reading and parsing all of them.
private func metricsFileCount() -> Int {
    ((try? FileManager.default.contentsOfDirectory(atPath: metricsFolderURL.path)) ?? []).filter { $0.hasSuffix(".json") }.count
}

/// The summary over every payload currently on disk; empty (not nil) when there are none yet.
func currentMetricsSummary() -> MetricsSummary {
    metricsFileCount() > 0 ? MetricsSummary.summarize(folder: metricsFolderURL) : MetricsSummary()
}

/// Any key the user can type on the command line: a name, "ctrl+option+f18", or a JSON object.
func parseKey(_ s: String) -> KeySpec? {
    if s.hasPrefix("{"), let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) { return KeySpec(json: o) }
    return KeySpec.named(s.lowercased()) ?? KeySpec(binding: s)
}

private func keyOrigin(_ p: VoiceProvider, user: KeySpec?) -> String {
    if user != nil { return "set by you" }
    if p.detected().key == nil { return "not found" }
    return p.readsSettings ? "auto-detected" : "default, unverified"
}

private func settingsDict() -> [String: Any] {
    let m = Model.shared, c = m.c
    return [
        "mode": c.triggerMode, "shortcut": c.trigger.map { $0.json } ?? "follow", "any-key-stops": c.stopOnAnyKey,
        "source": c.voiceInput, "talk-key": m.userVoiceKey.map { $0.json } ?? "auto",
        "style": c.voiceStyles[c.voiceInput] ?? "auto",
        "menu-bar-icon": c.showMenuBarIcon, "dock-icon": c.showDockIcon, "language": c.language,
        "hold-delay": c.holdDelay, "restore-timeout": c.restoreTimeout, "fallback-delay": c.fallbackDelay,
    ]
}

// MARK: commands

func cliStatus(json: Bool) -> Int32 {
    let m = Model.shared, c = m.c, p = m.provider, st = AppState.read()
    if json {
        printJSON([
            "version": appVersion, "running": st != nil, "pid": st.map { Int($0.pid) } as Any,
            "accessibility": st.map { $0.trusted } as Any, "keyListener": st.map { $0.tapActive } as Any,
            "secureInput": st.map { $0.secureInput } as Any, "secureInputApp": st?.secureInputApp as Any,
            "mode": c.triggerMode, "shortcut": m.trigger.name,
            "source": ["id": p.id, "name": p.name, "installed": p.isInstalled],
            "talkKey": ["key": m.forwardKey.name, "origin": keyOrigin(p, user: m.userVoiceKey)],
            "style": m.voiceStyle, "configError": c.lastError as Any,
        ])
        return 0
    }
    print("Hijack \(appVersion) (commit \(appCommit)) — " + (st.map { "running (pid \($0.pid))" } ?? "not running"))
    if let st {
        print("  accessibility   " + (st.trusted ? "allowed" : "MISSING — System Settings › Privacy & Security › Accessibility"))
        print(
            "  key listener    "
                + (st.tapActive
                    ? "active" : st.trusted ? "OFF — macOS turned it off; quit and reopen Hijack" : "off — waiting for Accessibility"))
        if st.secureInput { print("  secure input    on" + (st.secureInputApp.map { " (\($0))" } ?? "")) }
    }
    print("  mode            " + (m.toggleMode ? "toggle (tap to start, tap to stop)" : "hold (hold to talk)"))
    print("  shortcut        \(m.trigger.name)" + (c.trigger == nil ? "  (same as talk key)" : ""))
    print("  voice source    \(p.name)  [\(p.id)]" + (p.isInstalled ? "" : "  NOT INSTALLED"))
    print("  talk key        \(m.forwardKey.name)  (\(keyOrigin(p, user: m.userVoiceKey)))")
    print("  starts with     \(m.voiceStyle)")
    if let e = c.errorText { print("  config          ERROR — \(e)") }
    return 0
}

func cliDoctor() -> Int32 {
    let m = Model.shared, c = m.c, p = m.provider, st = AppState.read()
    var failed = false
    func check(_ ok: Bool?, _ label: String, _ fix: String = "") {
        let mark = ok == true ? "✓" : ok == false ? "✗" : "⚠︎"
        if ok == false { failed = true }
        print("\(mark) \(label)" + (ok == true || fix.isEmpty ? "" : "\n    → \(fix)"))
    }
    check(c.lastError == nil, "config file is valid JSON", "fix or revert ~/.config/hijack/config.json")
    check(st != nil, "Hijack is running", "open /Applications/Hijack.app")
    if let st {
        check(st.trusted, "Accessibility permission granted", "System Settings › Privacy & Security › Accessibility › turn on Hijack")
        check(
            st.tapActive, "key listener installed", st.trusted ? "macOS turned it off; quit and reopen Hijack" : "grant Accessibility first"
        )
    }
    check(p.isInstalled, "voice source \(p.name) is installed", "install it, or `hijack set source <id>` (see `hijack sources`)")
    let found = p.detected().key
    if m.userVoiceKey != nil {
        check(true, "talk key \(m.forwardKey.name) (set by you)")
    } else if let found {
        if !p.readsSettings {
            check(
                nil, "talk key \(found.name) is a default, not read from \(p.name)",
                "make sure \(p.name) uses \(found.name), or `hijack set talk-key <key>`")
        } else {
            check(true, "talk key \(found.name) read from \(p.name)'s settings")
        }
    } else {
        check(false, "talk key of \(p.name) detected", "`hijack set talk-key <key>` to match \(p.name)'s own setting")
    }
    let t = m.trigger
    check(
        t.modifierOnly || !t.mods.isEmpty || t.code >= 96 ? true : nil, "shortcut \(t.name) won't fire while typing",
        "a plain key also triggers while you type — prefer a modifier (right_option) or a combo")
    if p.switchesInputSource {
        check(
            p.isBusy() != nil ? true : nil, "can watch \(p.name)'s window to know when the text is in",
            "\(p.name) isn't running now; Hijack falls back to waiting \(c.fallbackDelay)s")
    }
    // MetricKit crash diagnostics only come in a few hours after the crash (review-5 #17's own kind of
    // delay): a crash that post-dates the app's own last start is still worth a look now. Compared
    // against `st.startedAt` (review 6, S2), not `st.updated` — `updated` moves on every dictation and
    // menu open, so it can hide a crash that happened before the latest one of those but after this run
    // actually started.
    if let st, MetricsSummary.crashIsNewerThanStart(lastCrash: currentMetricsSummary().lastCrashDate, startedAt: st.startedAt) {
        check(nil, "a crash report newer than the last start", "see `hijack stats` and ~/Library/Logs/Hijack-metrics")
    }
    print(failed ? "\nSomething needs fixing." : "\nAll good.")
    return failed ? 1 : 0
}

func cliSources(json: Bool) -> Int32 {
    let m = Model.shared, c = m.c
    var list = installedProviders()
    if !list.contains(where: { $0.id == c.voiceInput }) { list.append(voiceProvider(for: c.voiceInput)) }
    let rows: [[String: Any]] = list.map { p in
        let user = c.voiceKeys[p.id], key = user ?? p.detected().key
        return [
            "id": p.id, "name": p.name, "kind": p.switchesInputSource ? "input method" : "app",
            "current": p.id == c.voiceInput, "installed": p.isInstalled,
            "talkKey": key?.name as Any, "talkKeyOrigin": keyOrigin(p, user: user),
            "style": c.voiceStyles[p.id] ?? p.detected().style ?? "hold",
        ]
    }
    if json { printJSON(rows); return 0 }
    for r in rows {
        let current = (r["current"] as? Bool) ?? false, installed = (r["installed"] as? Bool) ?? false
        let name = (r["name"] as? String) ?? "?", id = (r["id"] as? String) ?? "?"
        let kind = (r["kind"] as? String) ?? "?", style = (r["style"] as? String) ?? "?"
        let talkKeyOrigin = (r["talkKeyOrigin"] as? String) ?? "?"
        print("\(current ? "*" : " ") \(name)  [\(id)]")
        print(
            "    \(kind) · talk key \((r["talkKey"] as? String) ?? "?") (\(talkKeyOrigin)) · starts with \(style)"
                + (installed ? "" : " · NOT INSTALLED"))
    }
    return 0
}

func cliGet(_ name: String?, json: Bool) -> Int32 {
    let d = settingsDict()
    if let name {
        guard let v = d[name] else { return fail("unknown setting '\(name)' — see `hijack help`") }
        if json { printJSON([name: v]) } else { print(v is [String: Any] ? jsonString(v) : "\(v)") }
        return 0
    }
    if json { printJSON(d); return 0 }
    for (k, v) in d.sorted(by: { $0.key < $1.key }) { print("\(k): " + (v is [String: Any] ? jsonString(v) : "\(v)")) }
    return 0
}

private func jsonString(_ v: Any) -> String {
    (try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "\(v)"
}

func cliSet(_ args: [String]) -> Int32 {
    guard args.count >= 2 else { return fail("usage: hijack set <setting> <value>") }
    let name = args[0], value = args[1...].joined(separator: " ")
    let c = Config.shared; c.reload(force: true)
    if c.lastError != nil { return fail("the config file has an error; fix or revert it first (~/.config/hijack/config.json)") }
    func bool() -> Bool? {
        ["true": true, "on": true, "yes": true, "1": true, "false": false, "off": false, "no": false, "0": false][value.lowercased()]
    }
    func seconds(_ r: ClosedRange<Double>) -> Double? { Double(value).flatMap { r.contains($0) ? $0 : nil } }
    switch name {
    case "mode":
        guard ["hold", "toggle"].contains(value) else { return fail("mode: hold | toggle") }
        c.triggerMode = value
    case "shortcut":
        if value == "follow" {
            c.trigger = nil
        } else {
            guard let k = parseKey(value) else { return fail("shortcut: follow, or a key like right_option, fn, f18, ctrl+option+f18") };
            c.trigger = k
        }
    case "any-key-stops":
        guard let b = bool() else { return fail("any-key-stops: true | false") }; c.stopOnAnyKey = b
    case "source":
        let all = builtInProviders + installedProviders()
        let match = all.first { $0.id == value } ?? all.first { $0.name.lowercased() == value.lowercased() }
        let id = match?.id ?? value
        let p = voiceProvider(for: id)
        if !p.isInstalled {
            FileHandle.standardError.write("warning: \(p.name) [\(id)] isn't installed\n".data(using: .utf8) ?? Data())
        }
        c.voiceInput = id
    case "talk-key":
        if value == "auto" {
            c.voiceKeys[c.voiceInput] = nil
        } else {
            guard let k = parseKey(value) else { return fail("talk-key: auto, or a key like fn, right_option, option+space") };
            c.voiceKeys[c.voiceInput] = k
        }
    case "style":
        guard ["auto", "hold", "tap", "doubleTap"].contains(value) else { return fail("style: auto | hold | tap | doubleTap") }
        c.voiceStyles[c.voiceInput] = value == "auto" ? nil : value
    case "menu-bar-icon":
        guard let b = bool() else { return fail("menu-bar-icon: true | false") }; c.showMenuBarIcon = b
    case "dock-icon":
        guard let b = bool() else { return fail("dock-icon: true | false") }; c.showDockIcon = b
    case "language":
        guard ["system", "en", "zh"].contains(value) else { return fail("language: system | en | zh") }; c.language = value
    case "hold-delay":
        // Ranges shared with Config's own load-time clamp (Sources/Core/ConfigValues.swift, review-5 #14):
        // a hand edit of config.json bypasses this validation, so loading enforces the same bounds again.
        guard let s = seconds(holdDelayRange) else { return fail("hold-delay: 0.05–1 seconds") }; c.holdDelay = s
    case "restore-timeout":
        guard let s = seconds(restoreTimeoutRange) else { return fail("restore-timeout: 1–15 seconds") }; c.restoreTimeout = s
    case "fallback-delay":
        guard let s = seconds(fallbackDelayRange) else { return fail("fallback-delay: 0.5–10 seconds") }; c.fallbackDelay = s
    default:
        return fail("unknown setting '\(name)' — see `hijack help`")
    }
    c.save()
    log("cli: set \(name) \(value)")
    let d = settingsDict()
    print("\(name): " + (d[name].map { $0 is [String: Any] ? jsonString($0) : "\($0)" } ?? value))
    return 0
}

func cliLog(_ args: [String]) -> Int32 {
    var n = 20, follow = false
    if args.contains("--live") {  // the step-level trace lives in the system log at debug level
        let stream = Process()
        stream.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        stream.arguments = ["stream", "--level", "debug", "--style", "compact", "--predicate", "subsystem == \"com.zl190.hijack\""]
        do { try stream.run(); stream.waitUntilExit(); return stream.terminationStatus } catch { return fail("can't run /usr/bin/log") }
    }
    var i = 0
    while i < args.count {
        if args[i] == "-f" { follow = true } else if args[i] == "-n", i + 1 < args.count, let v = Int(args[i + 1]) { n = v; i += 1 }
        i += 1
    }
    let tail = Process()
    tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
    tail.arguments = (follow ? ["-F"] : []) + ["-n", "\(n)", logURL.path]
    do { try tail.run(); tail.waitUntilExit(); return tail.terminationStatus } catch { return fail("can't read \(logURL.path)") }
}

func cliStats(_ args: [String], json: Bool) -> Int32 {
    var days: Int? = 7
    if args.contains("--all") { days = nil }
    if let i = args.firstIndex(of: "--days") {
        guard i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else { return fail("--days needs a number of days") }
        days = n
    }
    let old = logURL.deletingPathExtension().appendingPathExtension("old.log")
    let lines = [old, logURL].flatMap { (try? String(contentsOf: $0, encoding: .utf8))?.components(separatedBy: "\n") ?? [] }
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
    let s = DictationStats.compute(lines: lines, days: days, today: f.string(from: Date()))
    let span = days.map { "last \($0) days" } ?? "all of the log"
    // review-5 #17: s.tools is keyed by whatever Engine.summary wrote (a provider id since this change, a
    // display name on an older line). voiceProvider(for:) resolves a known id to its display name; an
    // unresolved key (an old line, or an id no longer installed) comes back unchanged.
    let toolNames = Dictionary(s.tools.map { (voiceProvider(for: $0.key).name, $0.value) }, uniquingKeysWith: +)
    let hasPayloads = metricsFileCount() > 0
    let metrics = currentMetricsSummary()
    if json {
        var d: [String: Any] = [
            "span": span, "dictations": s.dictations, "tooShort": s.tooShort,
            "outcomes": Dictionary(uniqueKeysWithValues: s.outcomes.map { ($0.key.rawValue, $0.value) }),
            "failureCauses": Dictionary(uniqueKeysWithValues: s.causes.map { ($0.key.rawValue, $0.value) }),
            "tools": toolNames, "keyTapPaused": s.tapPaused, "slowKeyEvents": s.slowKeys, "triggerCaughtUp": s.caughtUp,
            "system": systemJSON(metrics, hasPayloads: hasPayloads),
        ]
        if let r = s.successRate { d["successRate"] = (r * 1000).rounded() / 1000 }
        // W2 SLO: `target` is always carried (it's a fixed policy value); `met` is carried only when
        // `successRate` could be computed — omitted, like successRate itself, when nothing was judged yet.
        d["target"] = DictationStats.successTarget
        if let met = s.met { d["met"] = met }
        for (k, v) in [
            ("talkKeyMsP50", s.sentP50), ("talkKeyMsP95", s.sentP95), ("textInMsP50", s.textInP50), ("textInMsP95", s.textInP95),
        ] {
            if let v { d[k] = v }
        }
        printJSON(d); return 0
    }
    print("Hijack stats · \(span)" + (s.firstDay.map { " (\($0) → \(s.lastDay ?? $0))" } ?? ""))
    if s.dictations == 0 {
        print("No dictations logged yet (the log has them since 1.1.2).")
    } else {
        func row(_ label: String, _ n: Int, _ note: String = "") {
            let share = String(format: "%3.0f%%", Double(n) / Double(s.dictations) * 100)
            print("  " + label.padding(toLength: 22, withPad: " ", startingAt: 0) + String(format: "%5d", n) + "  \(share)" + note)
        }
        print(
            "Dictations".padding(toLength: 24, withPad: " ", startingAt: 0) + String(format: "%5d", s.dictations)
                + (s.tooShort > 0 ? "  (+\(s.tooShort) too short to start)" : ""))
        for o in DictationEntry.Outcome.allCases where o != .tooShort { if let n = s.outcomes[o] { row(o.rawValue, n) } }
        for c in DictationEntry.Cause.allCases { if let n = s.causes[c] { print("      \(n) × \(c.rawValue)") } }
        // The target line sits right under the rate it judges. No line at all when nothing was judged yet
        // (same choice as --json, which then omits "met" rather than printing a meaningless comparison).
        if let r = s.successRate, let met = s.met {
            print(
                "Success rate".padding(toLength: 24, withPad: " ", startingAt: 0) + String(format: "%5.1f%%", r * 100)
                    + "  (text arrived ÷ text arrived + no window)")
            print(
                "target".padding(toLength: 24, withPad: " ", startingAt: 0)
                    + "success >= \(String(format: "%.1f", DictationStats.successTarget * 100))%  this period \(String(format: "%.1f", r * 100))%  "
                    + (met ? "met" : "not met"))
        }
        func ms(_ v: Int?) -> String { v.map { $0 < 1000 ? "\($0) ms" : String(format: "%.2f s", Double($0) / 1000) } ?? "–" }
        print("Talk key sent after".padding(toLength: 24, withPad: " ", startingAt: 0) + "p50 \(ms(s.sentP50))   p95 \(ms(s.sentP95))")
        print(
            "Text in after release".padding(toLength: 24, withPad: " ", startingAt: 0) + "p50 \(ms(s.textInP50))   p95 \(ms(s.textInP95))")
        print(
            "Incidents".padding(toLength: 24, withPad: " ", startingAt: 0)
                + "key tap paused by macOS \(s.tapPaused) · slow key events \(s.slowKeys) · shortcut caught up \(s.caughtUp)")
        if toolNames.count > 1 {
            print(
                "By voice tool".padding(toLength: 24, withPad: " ", startingAt: 0)
                    + toolNames.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
        }
    }
    printSystemBlock(metrics, hasPayloads: hasPayloads)
    return 0
}

/// `system` in `hijack stats --json`: MetricsSummary's fields, plus `hasPayloads` since an absent key
/// elsewhere in `d` would otherwise be the only way to tell "no payloads yet" from "all zero".
private func systemJSON(_ m: MetricsSummary, hasPayloads: Bool) -> [String: Any] {
    guard hasPayloads else { return ["hasPayloads": false] }
    var d: [String: Any] = [
        "hasPayloads": true, "hangs": m.hangCount, "crashes": m.crashCount, "cpuSecondsByDay": m.cpuSecondsByDay,
        // review 6 (S1c): a key that existed but did not parse must be counted here, not read as a silent 0/absent.
        "parseWarnings": m.parseWarnings,
    ]
    if let v = m.longestHangSeconds { d["longestHangSeconds"] = v }
    if let v = m.peakMemoryBytes { d["peakMemoryBytes"] = v }
    if let v = m.lastCrashDate { d["lastCrashDate"] = ISO8601DateFormatter().string(from: v) }
    return d
}

/// The "System (MetricKit)" block of `hijack stats` (text form): hang count and longest hang, crash
/// count and last crash date, CPU time per day, peak memory — or one line when nothing has arrived yet.
/// review 6 (S1c): a field whose key existed but never parsed prints "n/a (unrecognized format)" rather
/// than being silently absent, which would read as "Hijack has no data" instead of "Hijack could not read it".
private func printSystemBlock(_ m: MetricsSummary, hasPayloads: Bool) {
    let unrecognized = "n/a (unrecognized format)"
    func row(_ label: String, _ text: String) { print(label.padding(toLength: 24, withPad: " ", startingAt: 0) + text) }
    guard hasPayloads else {
        row("System (MetricKit)", "no payloads yet (macOS delivers them about once a day)")
        return
    }
    func seconds(_ v: Double) -> String { String(format: "%.2fs", v) }
    let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    print("System (MetricKit)")
    let hangSuffix =
        m.longestHangSeconds.map { "  (longest \(seconds($0)))" } ?? (m.longestHangUnparsed ? "  (longest \(unrecognized))" : "")
    row("  Hangs", "\(m.hangCount)" + hangSuffix)
    row("  Crashes", "\(m.crashCount)" + (m.lastCrashDate.map { "  (last \(day.string(from: $0)))" } ?? ""))
    if m.cpuSecondsByDay.isEmpty, m.cpuTimeUnparsed {
        row("  CPU time", unrecognized)
    } else {
        for (d, cpu) in m.cpuSecondsByDay.sorted(by: { $0.key < $1.key }) { row("  CPU time \(d)", seconds(cpu)) }
    }
    if let peak = m.peakMemoryBytes {
        row("  Peak memory", String(format: "%.1f MB", peak / 1e6))
    } else if m.peakMemoryUnparsed {
        row("  Peak memory", unrecognized)
    }
}
