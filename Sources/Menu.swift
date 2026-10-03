import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

// MARK: menu (the whole UI)

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine: Engine = Engine.live()
    let m: Model = .shared
    let menu: NSMenu = NSMenu()
    var item: NSStatusItem?
    var watch: SettingsWatch?

    func applicationDidFinishLaunching(_ n: Notification) {
        logInApp = true
        menu.delegate = self
        applyAppearance()
        // Pick up icon/Dock changes made from the CLI or a hand edit.
        // Settings apply when their files change (config, a voice tool's own settings): no polling.
        // The config folder must exist before the watch starts: the watch covers only folders that exist (FM-18).
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        watch = SettingsWatch(paths: [configURL] + voiceSettingsFiles) { [weak self] in
            Config.shared.reload(); self?.applyAppearance(); self?.engine.refresh()
            NotificationCenter.default.post(name: .hijackSettingsChanged, object: nil)
        }
        trace("watching settings in \(self.watch!.roots.joined(separator: ", "))")
        // Registered before start(): start() can post .hijackStateChanged before this function returns
        // (waiting for Accessibility, or the tap install itself), and the icon must see it (review-4 M1).
        NotificationCenter.default.addObserver(forName: .hijackStateChanged, object: nil, queue: .main) { [weak self] _ in self?.updateIcon() }
        engine.start()
        // Sleep, wake and lock land in the log, to line them up with a session that stops working.
        let ws = NSWorkspace.shared.notificationCenter
        // After wake and after unlock the engine also reconciles: a session across sleep stops, the trigger is re-read (FM-25).
        for (name, text) in [(NSWorkspace.willSleepNotification, "system sleep"), (NSWorkspace.didWakeNotification, "system wake"),
                             (NSWorkspace.screensDidSleepNotification, "screens sleep"), (NSWorkspace.screensDidWakeNotification, "screens wake"),
                             (NSWorkspace.sessionDidResignActiveNotification, "session inactive"), (NSWorkspace.sessionDidBecomeActiveNotification, "session active")] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                log(text)
                if name == NSWorkspace.willSleepNotification { self?.engine.systemWillSleep() }
                if name == NSWorkspace.didWakeNotification { self?.engine.reconcileAfterWake(.systemWake) }
            }
        }
        for (name, text) in [("com.apple.screenIsLocked", "screen locked"), ("com.apple.screenIsUnlocked", "screen unlocked")] {
            DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                log(text)
                if text == "screen locked" { self?.engine.screenLocked() }
                if text == "screen unlocked" { self?.engine.reconcileAfterWake(.screenUnlock) }
            }
        }
        // Secure Input can only be read live (Accessibility's own); keep state.json fresh at the one other
        // natural moment besides a menu open — the end of a dictation (docs/hci-review-faults.md §5 item 4).
        NotificationCenter.default.addObserver(forName: .hijackActivity, object: nil, queue: .main) { [weak self] n in
            // An app tool's "done" post can come from inside the tap callback (NSNotificationCenter's .main
            // queue runs inline when the post is already on main): hop off it before the file I/O (review-4 M2).
            guard (n.userInfo?["phase"] as? String) == "done" else { return }
            DispatchQueue.main.async { self?.writeSecureInputState() }
        }
        // Reopens Hijack after an installer replaces it (brew can't: its install sandbox denies launching apps).
        // The system keeps the plist from registration time, so re-register when the bundled one changes.
        let plist = "com.zl190.hijack.relauncher.plist"
        let relauncher = SMAppService.agent(plistName: plist)
        let current = (try? Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/" + plist)))?.base64EncodedString()
        if relauncher.status != .enabled || UserDefaults.standard.string(forKey: "relauncherPlist") != current {
            try? relauncher.unregister()
            if (try? relauncher.register()) != nil { UserDefaults.standard.set(current, forKey: "relauncherPlist") }
        }
        if !AXIsProcessTrusted() {   // first run: the window explains what's missing; the system prompt adds us to the list
            SettingsWindowController.show()
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
    }

    // Opening the app again (Finder / Spotlight / LaunchBar / Dock) shows the settings window,
    // so everything stays reachable with both icons hidden.
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        SettingsWindowController.show()
        return false
    }

    // Menu bar icon + Dock icon follow the config.
    func applyAppearance() {
        updateIcon()
        let policy: NSApplication.ActivationPolicy = Config.shared.showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if policy == .regular { installMainMenu(); SettingsWindowController.shared?.window?.makeKeyAndOrderFront(nil) }
        }
    }

    // With a Dock icon Hijack is a regular app, so it gets the standard app menu (Settings… ⌘, and Quit ⌘Q).
    func installMainMenu() {
        let main = NSMenu(), appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: L("设置…", "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: L("隐藏 \(appName)", "Hide \(appName)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: L("退出 \(appName)", "Quit \(appName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: L("窗口", "Window"))
        windowMenu.addItem(NSMenuItem(title: L("关闭", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        NSApp.mainMenu = main
    }

    @objc func openSettings() { SettingsWindowController.show() }
    @objc func recordShortcut() { SettingsWindowController.show(tab: 0); SettingsStore.shared.startRecording(.trigger) }
    @objc func recordTalkKey() { SettingsWindowController.show(tab: 1); SettingsStore.shared.startRecording(.voiceKey(m.voiceID)) }

    /// Two icon states only (Idle, Off): §3.1 ruled out a third "Active" state as main-thread cost on every
    /// talk-key edge (FM-26). Off covers both a dead key listener (FM-02) and missing/revoked Accessibility.
    func updateIcon() {
        guard Config.shared.showMenuBarIcon else {
            if let it = item { NSStatusBar.system.removeStatusItem(it); item = nil }
            return
        }
        let it = item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if item == nil { it.menu = menu; item = it }
        let state = IconState.of(trusted: AXIsProcessTrusted(), tapActive: engine.tap.isEnabled, tapInstalled: engine.tapInstalled)
        let resource = state == .idle ? "HijackMenuTemplate" : "HijackMenuTemplate-Off"
        let icon = Bundle.main.image(forResource: resource)
            ?? NSImage(systemSymbolName: state == .idle ? "mic" : "mic.slash", accessibilityDescription: appName)
        icon?.isTemplate = true                  // follows light/dark menu bar
        icon?.size = NSSize(width: 18, height: 18)
        icon?.accessibilityDescription = state == .idle ? L("Hijack", "Hijack") : L("Hijack：快捷键无效", "Hijack: shortcut not working")
        it.button?.image = icon
    }

    /// Secure Input (Carbon's own call) at the two moments state.json is refreshed for it: a menu open, and
    /// the end of a dictation. The CLI reads it from there — see the comment on `AppState.secureInput`.
    func writeSecureInputState() {
        let on = engine.tap.secureInputOn
        AppState.write(trusted: AXIsProcessTrusted(), tapActive: engine.tap.isEnabled,
                       secureInput: on, secureInputApp: on ? NSWorkspace.shared.frontmostApplication?.localizedName : nil)
    }

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

        // Refresh state.json for Secure Input here too, so a CLI check right after the user looks is fresh.
        writeSecureInputState()

        // Status — derived from the same state the engine uses. At most one fault line replaces the normal
        // status line (docs/hci-review-faults.md §3.2): a dead key listener first, then a stuck session,
        // then Secure Input. "No Accessibility" is checked first; it already has its own line and is the
        // more fundamental cause when both are true.
        let stillHolding = MenuFaults.stillHoldingTalkKey(toggle: engine.plan.toggle, isActive: engine.machine.isActive,
                                                           keyIsPhysicallyDown: engine.tap.keyIsDown(engine.plan.trigger.code),
                                                           talkKeyName: engine.plan.forwardKey.name)
        let secureApp = engine.tap.secureInputOn ? (NSWorkspace.shared.frontmostApplication?.localizedName ?? L("另一个 app", "Another app")) : nil
        let fault = MenuFaults.firstLine(tapActive: engine.tap.isEnabled, stillHoldingTalkKey: stillHolding, secureInputApp: secureApp)
        if !AXIsProcessTrusted() {
            add(L("⚠︎ 需要辅助功能权限，点这里去允许…", "⚠︎ Needs Accessibility permission — Allow…"), #selector(openAccessibility))
        } else if let fault {
            switch fault {
            case .keyListenerOff:
                add(L("⚠︎ 系统关掉了按键监听，快捷键无效，点这里重新打开 Hijack", "⚠︎ macOS turned off the key listener; the shortcut does nothing — Reopen Hijack"), #selector(relaunchApp))
            case .stillHolding(let talkKey):
                add(L("⚠︎ Hijack 还按着\(talkKey)，点这里松开", "⚠︎ Hijack is still holding \(talkKey) — Release"), #selector(releaseStuckSession))
            case .secureInput(let app):
                add(L("⚠︎ \(app)开着安全输入（常见于密码框），关掉前快捷键无效", "⚠︎ \(app) has Secure Input on (often a password field). The shortcut won't work until it's off"))
            }
        } else if m.toggleMode {
            add(L("点按\(key)用\(name)听写", "Tap \(key) to dictate with \(name)"))
        } else {
            add(L("按住\(key)用\(name)听写", "Hold \(key) to dictate with \(name)"))
        }
        if let err = c.errorText {   // settings can't be changed until the file is fixed
            add("⚠︎ " + err + L("，点这里打开", " — Open…"), #selector(openConfig))
        }
        let readable = m.provider.readsSettings
        if m.userVoiceKey == nil && (m.detectedVoiceKey == nil || !readable) {
            add(m.detectedVoiceKey.map { L("⚠︎ \(name)里的说话键用的是默认值\($0.name)，请确认一致", "⚠︎ \(name)'s talk key is assumed to be \($0.name) — make sure it matches") }
                ?? L("⚠︎ 读不到\(name)里的说话键，请在「语音来源」里选", "⚠︎ Can't detect \(name)'s talk key — pick it under Voice Source"))
        }
        menu.addItem(.separator())

        // How you dictate
        header(L("听写方式", "How You Dictate"))
        add(L("按住说话", "Hold to Talk"), #selector(setTriggerMode(_:)), on: !m.toggleMode, value: "hold")
        add(L("点按开始，再点停止（免按）", "Tap to Start, Tap to Stop"), #selector(setTriggerMode(_:)), on: m.toggleMode, value: "toggle")
        if m.toggleMode {   // how to stop, as a plain description (the switch itself lives in Settings → Dictation)
            let hint = add(c.stopOnAnyKey ? L("再点一下，或按任意键停止", "Tap again or press any key to stop") : L("再点一下停止", "Tap again to stop"))
            hint.attributedTitle = NSAttributedString(string: hint.title, attributes: [   // a description, aligned with the titles above
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        }
        let keys = NSMenu()
        add(L("同\(name)里的说话键（\(m.forwardKey.name)）", "Same as \(name)'s Talk Key (\(m.forwardKey.name))"), #selector(setTrigger(_:)), on: m.customTrigger == nil, to: keys, value: "auto")
        keys.addItem(.separator())
        for id in quickKeys { let k = KeySpec.named(id)!; add(k.name, #selector(setTrigger(_:)), on: m.customTrigger == k, to: keys, value: id) }
        if let t = m.customTrigger, t.quickID.map(quickKeys.contains) != true { add(t.name, on: true, to: keys) }
        keys.addItem(.separator())
        add(L("其他按键…", "Other Key…"), #selector(recordShortcut), to: keys)
        add(L("快捷键：\(key)", "Shortcut: \(key)")).submenu = keys
        menu.addItem(.separator())

        // Dictation source — only voice tools that are installed; its key and start style live here too.
        let src = NSMenu()
        var listed = Set<String>()
        for p in installedProviders() {
            add(p.name, #selector(setVoiceSource(_:)), on: m.voiceID == p.id, to: src, value: p.id)
            listed.insert(p.id)
        }
        if !listed.contains(m.voiceID) { add(L("\(name)（配置文件）", "\(name) (Config File)"), on: true, to: src) }
        src.addItem(.separator())
        header(L("\(name)里的说话键", "\(name)'s Talk Key"), to: src)
        let found = m.detectedVoiceKey
        let autoTitle: String = {
            guard let k = found else { return L("自动检测（没读到）", "Auto-Detect (Not Found)") }
            return readable ? L("\(k.name)（自动检测）", "\(k.name) (Auto-Detected)") : L("\(k.name)（默认，未验证）", "\(k.name) (Default, Unverified)")
        }()
        add(autoTitle, #selector(setVoiceKey(_:)), on: m.userVoiceKey == nil, to: src, value: "auto")
        for id in quickKeys where KeySpec.named(id) != found {
            let k = KeySpec.named(id)!; add(k.name, #selector(setVoiceKey(_:)), on: m.userVoiceKey == k, to: src, value: id)
        }
        if let u = m.userVoiceKey, u.quickID.map(quickKeys.contains) != true { add(u.name, on: true, to: src) }
        add(L("其他按键…", "Other Key…"), #selector(recordTalkKey), to: src)
        // Start style: only when the source can't simply be held (or the user changed it).
        if m.voiceStyle != "hold" || c.voiceStyles[m.voiceID] != nil {
            src.addItem(.separator())
            header(L("\(name)的启动方式", "How \(name) Starts"), to: src)
            let names = ["hold": L("按住", "Hold"), "tap": L("单击", "Single Tap"), "doubleTap": L("双击", "Double Tap")]
            for code in ["hold", "tap", "doubleTap"] {
                add(names[code]!, #selector(setVoiceStyle(_:)), on: m.voiceStyle == code, to: src, value: code)
            }
        }
        add(L("语音来源：\(name)", "Voice Source: \(name)")).submenu = src
        menu.addItem(.separator())

        // Everything set once (login item, icons, language, config file, timings) lives in Settings.
        let settings = add(L("设置…", "Settings…"), #selector(openSettings))
        settings.keyEquivalent = ","; settings.keyEquivalentModifierMask = .command
        if #available(macOS 27.0, *) { settings.preferredImageVisibility = .hidden }   // no auto icon: keep titles aligned
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

    // FM-02: the key listener is off and the retry already failed (Engine.reenableTap). Quitting and
    // reopening installs a fresh tap; it is also the fix the menu line and `hijack doctor` give.
    // openApplication(at:) alone activates the already-running copy instead of starting a new one
    // (createsNewApplicationInstance defaults to false), so terminating right after it would just quit
    // Hijack with nothing to reopen it (review-4 M4). A detached `open -b` after this process has exited
    // starts a fresh one instead.
    @objc func relaunchApp() {
        log("menu: relaunching after the key listener was found off")
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "sleep 0.5; open -b com.zl190.hijack"]
        try? reopen.run()
        NSApp.terminate(nil)
    }

    // FM-01, FM-04, FM-25: the engine still thinks a session is active, but the physical key is already up.
    @objc func releaseStuckSession() { engine.stopStuckSession() }
}
