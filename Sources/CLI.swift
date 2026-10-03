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
    case "version": print(appVersion); return 0
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
  hijack version

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

private func fail(_ msg: String) -> Int32 { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); return 1 }

private func printJSON(_ obj: Any) {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
       let s = String(data: d, encoding: .utf8) { print(s) }
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
            "mode": c.triggerMode, "shortcut": m.trigger.name,
            "source": ["id": p.id, "name": p.name, "installed": p.isInstalled],
            "talkKey": ["key": m.forwardKey.name, "origin": keyOrigin(p, user: m.userVoiceKey)],
            "style": m.voiceStyle, "configError": c.lastError as Any,
        ])
        return 0
    }
    print("Hijack \(appVersion) — " + (st.map { "running (pid \($0.pid))" } ?? "not running"))
    if let st {
        print("  accessibility   " + (st.trusted ? "allowed" : "MISSING — System Settings › Privacy & Security › Accessibility"))
        print("  key listener    " + (st.tapActive ? "active" : "OFF — macOS turned it off; quit and reopen Hijack"))
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
        check(st.tapActive, "key listener installed", "macOS turned it off; quit and reopen Hijack")
    }
    check(p.isInstalled, "voice source \(p.name) is installed", "install it, or `hijack set source <id>` (see `hijack sources`)")
    let found = p.detected().key
    if m.userVoiceKey != nil { check(true, "talk key \(m.forwardKey.name) (set by you)") }
    else if found == nil { check(false, "talk key of \(p.name) detected", "`hijack set talk-key <key>` to match \(p.name)'s own setting") }
    else if !p.readsSettings { check(nil, "talk key \(found!.name) is a default, not read from \(p.name)", "make sure \(p.name) uses \(found!.name), or `hijack set talk-key <key>`") }
    else { check(true, "talk key \(found!.name) read from \(p.name)'s settings") }
    let t = m.trigger
    check(t.modifierOnly || !t.mods.isEmpty || t.code >= 96 ? true : nil, "shortcut \(t.name) won't fire while typing",
          "a plain key also triggers while you type — prefer a modifier (right_option) or a combo")
    if p.switchesInputSource {
        check(p.isBusy() != nil ? true : nil, "can watch \(p.name)'s window to know when the text is in",
              "\(p.name) isn't running now; Hijack falls back to waiting \(c.fallbackDelay)s")
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
        return ["id": p.id, "name": p.name, "kind": p.switchesInputSource ? "input method" : "app",
                "current": p.id == c.voiceInput, "installed": p.isInstalled,
                "talkKey": key?.name as Any, "talkKeyOrigin": keyOrigin(p, user: user),
                "style": c.voiceStyles[p.id] ?? p.detected().style ?? "hold"]
    }
    if json { printJSON(rows); return 0 }
    for r in rows {
        print("\((r["current"] as! Bool) ? "*" : " ") \(r["name"]!)  [\(r["id"]!)]")
        print("    \(r["kind"]!) · talk key \((r["talkKey"] as? String) ?? "?") (\(r["talkKeyOrigin"]!)) · starts with \(r["style"]!)"
              + ((r["installed"] as! Bool) ? "" : " · NOT INSTALLED"))
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
    for k in d.keys.sorted() { let v = d[k]!; print("\(k): " + (v is [String: Any] ? jsonString(v) : "\(v)")) }
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
    func bool() -> Bool? { ["true": true, "on": true, "yes": true, "1": true, "false": false, "off": false, "no": false, "0": false][value.lowercased()] }
    func seconds(_ r: ClosedRange<Double>) -> Double? { Double(value).flatMap { r.contains($0) ? $0 : nil } }
    switch name {
    case "mode":
        guard ["hold", "toggle"].contains(value) else { return fail("mode: hold | toggle") }
        c.triggerMode = value
    case "shortcut":
        if value == "follow" { c.trigger = nil }
        else { guard let k = parseKey(value) else { return fail("shortcut: follow, or a key like right_option, fn, f18, ctrl+option+f18") }; c.trigger = k }
    case "any-key-stops":
        guard let b = bool() else { return fail("any-key-stops: true | false") }; c.stopOnAnyKey = b
    case "source":
        let all = builtInProviders + installedProviders()
        let match = all.first { $0.id == value } ?? all.first { $0.name.lowercased() == value.lowercased() }
        let id = match?.id ?? value
        let p = voiceProvider(for: id)
        if !p.isInstalled { FileHandle.standardError.write("warning: \(p.name) [\(id)] isn't installed\n".data(using: .utf8)!) }
        c.voiceInput = id
    case "talk-key":
        if value == "auto" { c.voiceKeys[c.voiceInput] = nil }
        else { guard let k = parseKey(value) else { return fail("talk-key: auto, or a key like fn, right_option, option+space") }; c.voiceKeys[c.voiceInput] = k }
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
        guard let s = seconds(0.05...1) else { return fail("hold-delay: 0.05–1 seconds") }; c.holdDelay = s
    case "restore-timeout":
        guard let s = seconds(1...15) else { return fail("restore-timeout: 1–15 seconds") }; c.restoreTimeout = s
    case "fallback-delay":
        guard let s = seconds(0.5...10) else { return fail("fallback-delay: 0.5–10 seconds") }; c.fallbackDelay = s
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
    if args.contains("--live") {   // the step-level trace lives in the system log at debug level
        let stream = Process()
        stream.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        stream.arguments = ["stream", "--level", "debug", "--style", "compact", "--predicate", "subsystem == \"com.zl190.hijack\""]
        do { try stream.run(); stream.waitUntilExit(); return stream.terminationStatus } catch { return fail("can't run /usr/bin/log") }
    }
    var i = 0
    while i < args.count {
        if args[i] == "-f" { follow = true }
        else if args[i] == "-n", i + 1 < args.count, let v = Int(args[i + 1]) { n = v; i += 1 }
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
    if json {
        var d: [String: Any] = ["span": span, "dictations": s.dictations, "tooShort": s.tooShort,
            "outcomes": Dictionary(uniqueKeysWithValues: s.outcomes.map { ($0.key.rawValue, $0.value) }),
            "failureCauses": Dictionary(uniqueKeysWithValues: s.causes.map { ($0.key.rawValue, $0.value) }),
            "tools": s.tools, "keyTapPaused": s.tapPaused, "slowKeyEvents": s.slowKeys, "triggerCaughtUp": s.caughtUp]
        if let r = s.successRate { d["successRate"] = (r * 1000).rounded() / 1000 }
        for (k, v) in [("talkKeyMsP50", s.sentP50), ("talkKeyMsP95", s.sentP95), ("textInMsP50", s.textInP50), ("textInMsP95", s.textInP95)] {
            if let v { d[k] = v }
        }
        printJSON(d); return 0
    }
    print("Hijack stats · \(span)" + (s.firstDay.map { " (\($0) → \(s.lastDay ?? $0))" } ?? ""))
    guard s.dictations > 0 else { print("No dictations logged yet (the log has them since 1.1.2)."); return 0 }
    func row(_ label: String, _ n: Int, _ note: String = "") {
        let share = String(format: "%3.0f%%", Double(n) / Double(s.dictations) * 100)
        print("  " + label.padding(toLength: 22, withPad: " ", startingAt: 0) + String(format: "%5d", n) + "  \(share)" + note)
    }
    print("Dictations".padding(toLength: 24, withPad: " ", startingAt: 0) + String(format: "%5d", s.dictations)
          + (s.tooShort > 0 ? "  (+\(s.tooShort) too short to start)" : ""))
    for o in DictationEntry.Outcome.allCases where o != .tooShort { if let n = s.outcomes[o] { row(o.rawValue, n) } }
    for c in DictationEntry.Cause.allCases { if let n = s.causes[c] { print("      \(n) × \(c.rawValue)") } }
    if let r = s.successRate { print("Success rate".padding(toLength: 24, withPad: " ", startingAt: 0) + String(format: "%5.1f%%", r * 100) + "  (text arrived ÷ text arrived + no window)") }
    func ms(_ v: Int?) -> String { v.map { $0 < 1000 ? "\($0) ms" : String(format: "%.2f s", Double($0) / 1000) } ?? "–" }
    print("Talk key sent after".padding(toLength: 24, withPad: " ", startingAt: 0) + "p50 \(ms(s.sentP50))   p95 \(ms(s.sentP95))")
    print("Text in after release".padding(toLength: 24, withPad: " ", startingAt: 0) + "p50 \(ms(s.textInP50))   p95 \(ms(s.textInP95))")
    print("Incidents".padding(toLength: 24, withPad: " ", startingAt: 0) + "key tap paused by macOS \(s.tapPaused) · slow key events \(s.slowKeys) · shortcut caught up \(s.caughtUp)")
    if s.tools.count > 1 { print("By voice tool".padding(toLength: 24, withPad: " ", startingAt: 0) + s.tools.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")) }
    return 0
}
