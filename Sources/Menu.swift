import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

// MARK: menu (the whole UI)

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = Engine()
    let m = Model.shared
    let menu = NSMenu()
    var item: NSStatusItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self
        applyAppearance()
        engine.start()
        if !AXIsProcessTrusted() {   // system prompt also adds us to the Accessibility list
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
            add(L("点按 \(key) 用\(name)听写", "Tap \(key) to dictate with \(name)"))
        } else {
            add(L("按住 \(key) 用\(name)听写", "Hold \(key) to dictate with \(name)"))
        }
        let readable = m.provider.readsSettings
        if m.userVoiceKey == nil && (m.detectedVoiceKey == nil || !readable) {
            add(m.detectedVoiceKey.map { L("⚠︎ \(name)里的语音键用的是默认值 \($0.name)，请确认一致", "⚠︎ \(name)'s voice key is assumed to be \($0.name) — make sure it matches") }
                ?? L("⚠︎ 读不到\(name)里的语音键，请在「语音来源」里选", "⚠︎ Can't detect \(name)'s voice key — pick it under Dictation Source"))
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
        for p in installedProviders() {
            add(p.name, #selector(setVoiceSource(_:)), on: m.voiceID == p.id, to: src, value: p.id)
            listed.insert(p.id)
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
        let settings = add(L("设置…", "Settings…"), #selector(openSettings))
        settings.keyEquivalent = ","; settings.keyEquivalentModifierMask = .command
        if #available(macOS 27.0, *) { settings.preferredImageVisibility = .hidden }   // no auto icon: keep titles aligned
        add(L("编辑配置文件…", "Edit Config File…"), #selector(openConfig))
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
