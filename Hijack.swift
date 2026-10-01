// Hijack — hold a key to dictate with a voice input method (default WeType) from any input source; the previous input source
// comes back after release. Everything is set from its menu (menu bar icon, or open the app again).
// Other voice IMEs (unmaintained): defaults write com.zl190.hijack voiceInputSource <id>
// Build: ./install.sh
import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

let appName = "Hijack"
let restoreDelay = 5.0   // longest wait after release before switching back
let fallbackDelay = 2.5  // used when the voice input method shows no window to watch
let capsuleGrace = 0.15  // after its voice window disappears, wait this long, then switch back
let holdDelay = 0.2      // minimum hold before WeType gets the key (a quick tap does nothing)
let maxSwitchWait = 1.0  // give up waiting for the input source switch after this long
let marker: Int64 = 0x5357424B               // tags events we post ourselves
let weTypeID = "com.tencent.inputmethod.wetype.pinyin"

// MARK: language  (system by default; menu can force English or Chinese)

func zh() -> Bool {
    switch UserDefaults.standard.string(forKey: "language") ?? "system" {
    case "zh": return true
    case "en": return false
    default: return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    }
}
func L(_ zhText: String, _ en: String) -> String { zh() ? zhText : en }

// MARK: modifier-only keys

struct ModKey: Equatable {
    let code: CGKeyCode
    let zhName: String
    let enName: String
    let device: UInt64     // device-dependent bit, tells left from right
    let flag: CGEventFlags // device-independent modifier flag

    var name: String { L(zhName, enName) }

    static let all: [ModKey] = [
        ModKey(code: 61, zhName: "右 Option", enName: "Right Option", device: 0x40, flag: .maskAlternate),
        ModKey(code: 58, zhName: "左 Option", enName: "Left Option", device: 0x20, flag: .maskAlternate),
        ModKey(code: 54, zhName: "右 Command", enName: "Right Command", device: 0x10, flag: .maskCommand),
        ModKey(code: 62, zhName: "右 Control", enName: "Right Control", device: 0x2000, flag: .maskControl),
        ModKey(code: 60, zhName: "右 Shift", enName: "Right Shift", device: 0x04, flag: .maskShift),
        ModKey(code: 63, zhName: "Fn", enName: "Fn", device: 0, flag: .maskSecondaryFn),
    ]
    static func by(code: Int) -> ModKey? { all.first { Int($0.code) == code } }

    func isDown(_ flags: CGEventFlags) -> Bool {
        device == 0 ? flags.contains(flag) : flags.rawValue & device != 0
    }
}

// WeType keeps its push-to-talk key in a private MMKV store; read it (never write it).
// MMKV layout: a little-endian UInt32 with the live data length, then the data; updates are appended,
// so the last occurrence inside the live range is current. Bytes past that length are stale leftovers.
func weTypeVoiceKey() -> ModKey? {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WeType/mmkv/wetype.settings")
    guard let data = try? Data(contentsOf: url), data.count > 4 else { return nil }
    let live = Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
    guard live > 0, 4 + live <= data.count,
          let s = String(data: data.subdata(in: 4..<(4 + live)), encoding: .isoLatin1),
          let r = s.range(of: "voicePTTShortcut_keyCodes", options: .backwards) else { return nil }
    let tail = s[r.upperBound...].prefix(24)
    guard let open = tail.firstIndex(of: "["), let close = tail.firstIndex(of: "]"), open < close else { return nil }
    let codes = tail[tail.index(after: open)..<close].split(separator: ",")
        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    return codes.count == 1 ? ModKey.by(code: codes[0]) : nil
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
    guard let bundle = source(sourceID).flatMap({ prop($0, kTISPropertyBundleID) }),
          let pid = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle })?.processIdentifier
    else { return nil }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
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

// MARK: settings

final class Model {
    static let shared = Model()
    let defaults = UserDefaults.standard

    var voiceID: String {
        get { defaults.string(forKey: "voiceInputSource") ?? weTypeID }
        set { defaults.set(newValue == weTypeID ? nil : newValue, forKey: "voiceInputSource") }
    }
    var voiceName: String { sourceName(voiceID) }
    var isWeType: Bool { voiceID == weTypeID }
    // The voice method's own push-to-talk key: read from WeType, chosen by the user for others.
    var voiceKey: ModKey? {
        if isWeType, let k = weTypeVoiceKey() { return k }
        return (defaults.object(forKey: "voiceKey.\(voiceID)") as? Int).flatMap(ModKey.by(code:))
    }
    var forwardKey: ModKey { voiceKey ?? ModKey.all[0] }
    var customTrigger: ModKey? {
        get { (defaults.object(forKey: "triggerKey") as? Int).flatMap(ModKey.by(code:)) }
        set { defaults.set(newValue.map { Int($0.code) }, forKey: "triggerKey") }
    }
    var trigger: ModKey { customTrigger ?? forwardKey }
    var showIcon: Bool {
        get { defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showMenuBarIcon") }
    }
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

    func post(_ key: ModKey, down: Bool) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: down) else { return }
        e.type = .flagsChanged
        e.flags = down ? CGEventFlags(rawValue: key.flag.rawValue | key.device) : []
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        e.post(tap: .cghidEventTap)
    }

    func pressed() -> Bool {
        generation += 1
        pressedAt = Date()
        sawWindow = false
        let cur = currentID()
        // Already in the voice method and the trigger is its own key: let it see the real key.
        if cur == m.voiceID && m.trigger == m.forwardKey {
            passthrough = true; log("down: already voice IME, pass through"); return true
        }
        passthrough = false
        if let cur, cur != m.voiceID { previous = cur }
        log("down: \(cur ?? "?") \(focusDesc())")
        if cur != m.voiceID { switchTo(m.voiceID, "switch to") }
        let gen = generation, start = Date()
        func forwardWhenReady() {
            guard physicalDown, gen == generation else { log("released before forward"); return }
            let ready = currentID() == m.voiceID
            let waited = Date().timeIntervalSince(start)
            if (ready && waited >= holdDelay) || waited >= maxSwitchWait {
                forwarded = true
                post(m.forwardKey, down: true)
                log("forward \(m.forwardKey.enName) down after \(Int(waited * 1000))ms ready=\(ready) \(focusDesc())")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { forwardWhenReady() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { forwardWhenReady() }
        return false
    }

    func released() -> Bool {
        if passthrough { passthrough = false; log("up: pass through"); return true }
        if forwarded { post(m.forwardKey, down: false); forwarded = false; log("forward up \(focusDesc())") }
        let gen = generation, released = Date()
        var capsuleGone: Date?
        func restoreWhenDone() {
            guard gen == generation else { return }
            let waited = Date().timeIntervalSince(released)
            let visible = voiceWindowVisible(m.voiceID)
            if visible == true { sawWindow = true }
            if sawWindow && capsuleGone == nil && visible == false { capsuleGone = Date(); log("voice window gone after \(Int(waited * 1000))ms") }
            let graceDone = capsuleGone.map { Date().timeIntervalSince($0) >= capsuleGrace } ?? false
            guard graceDone || waited >= (sawWindow ? restoreDelay : fallbackDelay) else {
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
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .flagsChanged,
              event.getIntegerValueField(.eventSourceUserData) != marker,
              CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == m.trigger.code
        else { return Unmanaged.passUnretained(event) }
        let down = m.trigger.isDown(event.flags)
        var pass = passthrough
        if down && !physicalDown { physicalDown = true; pass = pressed() }
        else if !down && physicalDown { physicalDown = false; pass = released() }
        return pass ? Unmanaged.passUnretained(event) : nil
    }

    func start() {
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }   // wait for the grant
            return
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
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
        if m.showIcon, item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let icon = Bundle.main.image(forResource: "HijackMenuTemplate")
                ?? NSImage(systemSymbolName: "mic", accessibilityDescription: appName)
            icon?.isTemplate = true                  // follows light/dark menu bar
            icon?.size = NSSize(width: 18, height: 18)
            it.button?.image = icon
            it.menu = menu
            item = it
        } else if !m.showIcon, let it = item {
            NSStatusBar.system.removeStatusItem(it); item = nil
        }
    }

    // Rebuilt every time it opens, so it always shows the live state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?, state: Bool = false, tag: Int = 0, to: NSMenu? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self; i.state = state ? .on : .off; i.tag = tag
            (to ?? menu).addItem(i); return i
        }
        if AXIsProcessTrusted() {
            _ = add(L("按住 \(m.trigger.name) 用\(m.voiceName)说话", "Hold \(m.trigger.name) to dictate with \(m.voiceName)"), nil)
        } else {
            _ = add(L("需要辅助功能权限，点这里去允许…", "Needs Accessibility permission — allow…"), #selector(openAccessibility))
        }
        menu.addItem(.separator())

        let keys = NSMenu()
        _ = add(L("跟随语音键（\(m.forwardKey.name)）", "Same as voice key (\(m.forwardKey.name))"), #selector(setTrigger(_:)), state: m.customTrigger == nil, tag: -1, to: keys)
        keys.addItem(.separator())
        for k in ModKey.all where k != m.forwardKey {
            _ = add(k.name, #selector(setTrigger(_:)), state: m.customTrigger == k, tag: Int(k.code), to: keys)
        }
        let keyItem = add(L("触发键：\(m.trigger.name)", "Trigger key: \(m.trigger.name)"), nil)
        keyItem.submenu = keys
        let sources = NSMenu()
        for c in voiceCandidates() {
            let i = add(c.name, #selector(setVoiceSource(_:)), state: c.id == m.voiceID, to: sources)
            i.representedObject = c.id
        }
        add(L("语音输入法：\(m.voiceName)", "Voice input: \(m.voiceName)"), nil).submenu = sources
        if m.isWeType && weTypeVoiceKey() != nil {
            _ = add(L("它的语音键：\(m.forwardKey.name)（自动读取）", "Its voice key: \(m.forwardKey.name) (detected)"), nil)
        } else {
            let vk = NSMenu()
            for k in ModKey.all {
                _ = add(k.name, #selector(setVoiceKey(_:)), state: m.forwardKey == k, tag: Int(k.code), to: vk)
            }
            add(L("它的语音键：\(m.forwardKey.name)", "Its voice key: \(m.forwardKey.name)"), nil).submenu = vk
        }
        menu.addItem(.separator())

        _ = add(L("开机启动", "Launch at login"), #selector(toggleLogin), state: SMAppService.mainApp.status == .enabled)
        _ = add(L("在菜单栏显示图标", "Show in menu bar"), #selector(toggleIcon), state: m.showIcon)
        let langs = NSMenu()
        let lang = UserDefaults.standard.string(forKey: "language") ?? "system"
        for (code, title) in [("system", L("跟随系统", "System")), ("en", "English"), ("zh", "中文")] {
            let i = add(title, #selector(setLanguage(_:)), state: lang == code, to: langs)
            i.representedObject = code
        }
        add(L("语言", "Language"), nil).submenu = langs
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("退出 \(appName)", "Quit \(appName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func setTrigger(_ sender: NSMenuItem) {
        m.customTrigger = sender.tag < 0 ? nil : ModKey.by(code: sender.tag)
        log("trigger set to \(m.trigger.name)")
    }
    @objc func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        else { try? SMAppService.mainApp.register() }
    }
    @objc func setVoiceSource(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { m.voiceID = id; log("voice source set to \(id)") }
    }
    @objc func setVoiceKey(_ sender: NSMenuItem) {
        m.defaults.set(sender.tag, forKey: "voiceKey.\(m.voiceID)")
        log("voice key for \(m.voiceID) set to \(m.forwardKey.name)")
    }
    @objc func setLanguage(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String, forKey: "language")
    }
    @objc func toggleIcon() { m.showIcon.toggle(); updateIcon() }
    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
