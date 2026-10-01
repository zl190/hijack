// Hijack — hold a key to dictate with WeType from any input source; the previous input source
// comes back after release. Everything is set from its menu (menu bar icon, or open the app again).
// Other voice IMEs (unmaintained): defaults write com.zl190.hijack voiceInputSource <id>
// Build: ./install.sh
import AppKit
import ApplicationServices
import Carbon
import CoreAudio
import ServiceManagement

let appName = "Hijack"
let restoreDelay = 2.5   // longest wait after release before switching back (lets WeType commit)
let micGrace = 0.3       // after WeType releases the microphone, wait this long, then switch back
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
func weTypeVoiceKey() -> ModKey? {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WeType/mmkv/wetype.settings")
    guard let data = try? Data(contentsOf: url),
          let s = String(data: data, encoding: .isoLatin1) else { return nil }
    guard let r = s.range(of: "voicePTTShortcut_keyCodes", options: .backwards) else { return nil }
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

// Is any app using the default microphone? (WeType stops recording → time to switch back)
func micInUse() -> Bool {
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return false }
    var running = UInt32(0)
    size = UInt32(MemoryLayout<UInt32>.size)
    addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &running) == noErr else { return false }
    return running != 0
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

    var voiceKey: ModKey? { weTypeVoiceKey() }
    var forwardKey: ModKey { voiceKey ?? ModKey.all[0] }
    var customTrigger: ModKey? {
        get { (defaults.object(forKey: "triggerKey") as? Int).flatMap(ModKey.by(code:)) }
        set { defaults.set(newValue.map { Int($0.code) }, forKey: "triggerKey") }
    }
    var trigger: ModKey { customTrigger ?? forwardKey }
    var voiceID: String { defaults.string(forKey: "voiceInputSource") ?? weTypeID }
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
        let cur = currentID()
        // Already in WeType and the trigger is WeType's own key: let WeType see the real key.
        if cur == m.voiceID && m.trigger == m.forwardKey {
            passthrough = true; log("down: already voice IME, pass through"); return true
        }
        passthrough = false
        if let cur, cur != m.voiceID { previous = cur }
        log("down: \(cur ?? "?")")
        if cur != m.voiceID { switchTo(m.voiceID, "switch to") }
        let gen = generation, start = Date()
        func forwardWhenReady() {
            guard physicalDown, gen == generation else { log("released before forward"); return }
            let ready = currentID() == m.voiceID
            let waited = Date().timeIntervalSince(start)
            if (ready && waited >= holdDelay) || waited >= maxSwitchWait {
                forwarded = true
                post(m.forwardKey, down: true)
                log("forward down after \(Int(waited * 1000))ms ready=\(ready)")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { forwardWhenReady() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { forwardWhenReady() }
        return false
    }

    func released() -> Bool {
        if passthrough { passthrough = false; log("up: pass through"); return true }
        if forwarded { post(m.forwardKey, down: false); forwarded = false; log("forward up") }
        let gen = generation, released = Date()
        var micStopped: Date?
        func restoreWhenDone() {
            guard gen == generation else { return }
            let waited = Date().timeIntervalSince(released)
            if micStopped == nil && !micInUse() { micStopped = Date(); log("mic idle after \(Int(waited * 1000))ms") }
            let graceDone = micStopped.map { Date().timeIntervalSince($0) >= micGrace } ?? false
            guard graceDone || waited >= restoreDelay else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { restoreWhenDone() }; return
            }
            guard currentID() == m.voiceID, let prev = previous else { return }
            log("restore after \(Int(waited * 1000))ms")
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
            _ = add(L("按住 \(m.trigger.name) 用微信输入法说话", "Hold \(m.trigger.name) to dictate with WeType"), nil)
        } else {
            _ = add(L("需要辅助功能权限，点这里去允许…", "Needs Accessibility permission — allow…"), #selector(openAccessibility))
        }
        menu.addItem(.separator())

        let keys = NSMenu()
        _ = add(L("跟随微信（\(m.forwardKey.name)）", "Same as WeType (\(m.forwardKey.name))"), #selector(setTrigger(_:)), state: m.customTrigger == nil, tag: -1, to: keys)
        keys.addItem(.separator())
        for k in ModKey.all where k != m.forwardKey {
            _ = add(k.name, #selector(setTrigger(_:)), state: m.customTrigger == k, tag: Int(k.code), to: keys)
        }
        let keyItem = add(L("触发键：\(m.trigger.name)", "Trigger key: \(m.trigger.name)"), nil)
        keyItem.submenu = keys
        _ = add(L("微信的语音键：\(m.voiceKey?.name ?? "没读到，按右 Option 处理")", "WeType voice key: \(m.voiceKey?.name ?? "not found, assuming Right Option")"), nil)
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
