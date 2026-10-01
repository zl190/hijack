import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

// MARK: settings window — a view of ~/.config/hijack/config.json (the file stays the source of truth).
// Every change is written to the file at once; hand edits show up within a second.

enum RecordTarget: Equatable { case trigger, voiceKey(String) }

struct SourceRow: Identifiable {
    let id: String, name: String
    let detectedKey: KeySpec?, userKey: KeySpec?, readsSettings: Bool
    let style: String, styleIsSet: Bool
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var triggerMode = "hold"
    @Published var stopOnAnyKey = true
    @Published var trigger: KeySpec?
    @Published var voiceInput = ""
    @Published var sources: [SourceRow] = []
    @Published var showMenuBarIcon = true
    @Published var showDockIcon = false
    @Published var launchAtLogin = false
    @Published var language = "system"
    @Published var holdDelay = 0.2
    @Published var restoreTimeout = 5.0
    @Published var fallbackDelay = 2.5
    @Published var trusted = false
    @Published var configError: String?
    @Published var recording: RecordTarget?
    @Published var live = ""          // what the engine is doing right now
    @Published var last = ""          // how the last dictation went

    private var timer: Timer?
    private var monitor: Any?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        NotificationCenter.default.addObserver(forName: .hijackActivity, object: nil, queue: .main) { [weak self] n in
            let phase = n.userInfo?["phase"] as? String ?? "", detail = n.userInfo?["detail"] as? String ?? ""
            switch phase {
            case "switching": self?.live = L("切到\(detail)…", "Switching to \(detail)…")
            case "listening": self?.live = L("正在听…", "Listening…")
            case "finishing": self?.live = L("说完了，等它上屏…", "Done talking, waiting for the text…")
            default: self?.live = ""; self?.last = detail.isEmpty ? L("完成", "Done") : detail
            }
        }
    }

    var engine: Engine? { (NSApp.delegate as? AppDelegate)?.engine }
    var model: Model { Model.shared }

    // Pull everything from the config file (and the system) into the published copies.
    func refresh() {
        let c = Config.shared; c.reload()
        triggerMode = c.triggerMode; stopOnAnyKey = c.stopOnAnyKey; trigger = c.trigger
        voiceInput = c.voiceInput
        showMenuBarIcon = c.showMenuBarIcon; showDockIcon = c.showDockIcon; language = c.language
        holdDelay = c.holdDelay; restoreTimeout = c.restoreTimeout; fallbackDelay = c.fallbackDelay
        configError = c.lastError
        launchAtLogin = SMAppService.mainApp.status == .enabled
        trusted = AXIsProcessTrusted()
        var rows = installedProviders()
        if !rows.contains(where: { $0.id == c.voiceInput }) { rows.append(voiceProvider(for: c.voiceInput)) }
        sources = rows.map { p in
            let d = p.detected()
            return SourceRow(id: p.id, name: p.name, detectedKey: d.key, userKey: c.voiceKeys[p.id], readsSettings: p.readsSettings,
                             style: c.voiceStyles[p.id] ?? d.style ?? "hold", styleIsSet: c.voiceStyles[p.id] != nil)
        }
    }

    // Change the config file, then re-read it and apply side effects (icons).
    func edit(_ change: (Config) -> Void) {
        let c = Config.shared; c.reload(force: true); change(c); c.save()
        refresh()
        (NSApp.delegate as? AppDelegate)?.applyAppearance()
    }

    var currentName: String { sources.first { $0.id == voiceInput }?.name ?? voiceInput }
    var voiceKeyForCurrent: KeySpec? { model.forwardKey }
    var effectiveTrigger: KeySpec { trigger ?? model.forwardKey }

    // MARK: key recording — any key, any combo, or a modifier alone (left/right told apart)

    func startRecording(_ target: RecordTarget) {
        stopRecording()
        recording = target
        engine?.paused = true            // otherwise pressing the current trigger would start a dictation
        var downModifier: Int?, sawOtherKey = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self, let target = self.recording else { return e }
            if e.type == .keyDown {
                sawOtherKey = true
                if e.keyCode == 53 && e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { self.stopRecording(); return nil }  // Esc
                let flags = e.modifierFlags
                var mods = Set<Mod>()
                if flags.contains(.control) { mods.insert(.ctrl) }
                if flags.contains(.option) { mods.insert(.option) }
                if flags.contains(.shift) { mods.insert(.shift) }
                if flags.contains(.command) { mods.insert(.command) }
                if flags.contains(.function) && !(122...126).contains(Int(e.keyCode)) && Int(e.keyCode) < 96 { mods.insert(.fn) }
                self.finish(target, KeySpec(code: Int(e.keyCode), mods: mods))
                return nil
            }
            // flagsChanged: a modifier pressed and released on its own is the key itself
            let code = Int(e.keyCode)
            guard let n = KeySpec(code: code).named, n.flag != nil else { return nil }
            let isDown = n.device == 0 ? e.modifierFlags.contains(.function) : (UInt64(e.modifierFlags.rawValue) & n.device) != 0
            if isDown { downModifier = code; sawOtherKey = false }
            else if downModifier == code && !sawOtherKey { self.finish(target, KeySpec(code: code)) }
            return nil
        }
    }

    private func finish(_ target: RecordTarget, _ key: KeySpec) {
        switch target {
        case .trigger: edit { $0.trigger = key }
        case .voiceKey(let id): edit { $0.voiceKeys[id] = key }
        }
        log("settings: recorded \(key.name) for \(target)")
        stopRecording()
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = nil; engine?.paused = false
    }
}

// MARK: views

struct KeyRecorder: View {
    @ObservedObject var store: SettingsStore
    let target: RecordTarget
    let key: KeySpec
    var body: some View {
        let on = store.recording == target
        Button { on ? store.stopRecording() : store.startRecording(target) } label: {
            Text(on ? L("按下想用的键…（Esc 取消）", "Press a key… (Esc cancels)") : key.name)
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 96).padding(.horizontal, 8).frame(height: 22)
                .foregroundStyle(on ? Color.accentColor : .primary)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.18)))
        }.buttonStyle(.plain)
    }
}

struct ErrorBanner: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        if let e = store.configError {
            Label(e, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.85)))
                .padding([.horizontal, .top], 12)
        }
    }
}

struct DictationTab: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        VStack(spacing: 0) {
            ErrorBanner(store: store)
            Form {
                Section {
                    Picker(L("方式", "Mode"), selection: Binding(get: { store.triggerMode }, set: { v in store.edit { $0.triggerMode = v } })) {
                        Text(L("按住说话", "Hold to Talk")).tag("hold")
                        Text(L("点按开始，再点停止", "Tap to Start, Tap to Stop")).tag("toggle")
                    }.pickerStyle(.radioGroup)
                    if store.triggerMode == "toggle" {
                        Toggle(L("按任意键也可停止（这个键不会输入）", "Any key also stops (that key isn't typed)"),
                               isOn: Binding(get: { store.stopOnAnyKey }, set: { v in store.edit { $0.stopOnAnyKey = v } }))
                    }
                }
                Section {
                    LabeledContent(L("快捷键", "Shortcut")) {
                        HStack(spacing: 8) {
                            if store.trigger != nil {
                                Button(L("同语音键", "Same as Voice Key")) { store.edit { $0.trigger = nil } }.buttonStyle(.link)
                            } else {
                                Text(L("同语音键", "Same as voice key")).foregroundStyle(.secondary).font(.callout)
                            }
                            KeyRecorder(store: store, target: .trigger, key: store.effectiveTrigger)
                        }
                    }
                    if let t = store.trigger, !t.modifierOnly, t.mods.isEmpty, t.code < 96 {
                        Label(L("单独一个普通键当快捷键，平时打字按到它也会触发", "A plain key alone also triggers while you type"),
                              systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    }
                }
                Section(L("试一下", "Try It")) {
                    HStack(spacing: 10) {
                        Bars(live: store.live == L("正在听…", "Listening…"))
                        Text(store.live.isEmpty
                             ? (store.triggerMode == "toggle" ? L("点一下 \(store.effectiveTrigger.name)，说一句，再点一下", "Tap \(store.effectiveTrigger.name), say something, tap again")
                                                             : L("按住 \(store.effectiveTrigger.name) 说一句", "Hold \(store.effectiveTrigger.name) and say something"))
                             : store.live)
                        Spacer()
                    }
                    if !store.last.isEmpty {
                        Label(store.last, systemImage: "checkmark.circle").foregroundStyle(.secondary).font(.callout)
                    }
                }
            }.formStyle(.grouped)
        }.frame(width: 520).fixedSize(horizontal: false, vertical: true)
    }
}

struct Bars: View {
    let live: Bool
    var body: some View {
        TimelineView(.animation(paused: !live)) { t in
            HStack(spacing: 2.5) {
                ForEach(0..<5) { i in
                    let phase = t.date.timeIntervalSinceReferenceDate * 7 + Double(i) * 0.9
                    Capsule().frame(width: 3, height: live ? 4 + 10 * abs(sin(phase)) : 4)
                }
            }.frame(width: 26, height: 16).foregroundStyle(live ? Color.accentColor : .secondary)
        }
    }
}

struct SourcesTab: View {
    @ObservedObject var store: SettingsStore
    let styleNames = ["hold": L("按住", "Hold"), "tap": L("单击", "Single Tap"), "doubleTap": L("双击", "Double Tap")]
    var body: some View {
        VStack(spacing: 0) {
            ErrorBanner(store: store)
            Form {
                Section {
                    ForEach(store.sources) { s in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: s.id == store.voiceInput ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(s.id == store.voiceInput ? Color.accentColor : .secondary)
                                Text(s.name).font(.body.weight(s.id == store.voiceInput ? .semibold : .regular))
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { store.edit { $0.voiceInput = s.id } }
                            HStack(spacing: 8) {
                                Text(L("它的语音键", "Its voice key")).foregroundStyle(.secondary).font(.callout).frame(width: 90, alignment: .leading)
                                KeyRecorder(store: store, target: .voiceKey(s.id), key: s.userKey ?? s.detectedKey ?? KeySpec.named("right_option")!)
                                if s.userKey != nil {
                                    Button(L("恢复自动", "Use Detected")) { store.edit { $0.voiceKeys[s.id] = nil } }.buttonStyle(.link).font(.callout)
                                } else {
                                    Text(s.detectedKey == nil ? L("⚠︎ 没读到，请录制", "⚠︎ Not found — record it")
                                         : s.readsSettings ? L("自动检测", "Detected") : L("默认值，未验证", "Default, unverified"))
                                        .font(.callout).foregroundStyle(s.detectedKey == nil || !s.readsSettings ? Color.orange : .secondary)
                                }
                            }
                            HStack(spacing: 8) {
                                Text(L("启动方式", "Starts on")).foregroundStyle(.secondary).font(.callout).frame(width: 90, alignment: .leading)
                                Picker("", selection: Binding(get: { s.style }, set: { v in store.edit { $0.voiceStyles[s.id] = v } })) {
                                    ForEach(["hold", "tap", "doubleTap"], id: \.self) { Text(styleNames[$0]!).tag($0) }
                                }.labelsHidden().pickerStyle(.segmented).frame(width: 220)
                            }
                        }.padding(.vertical, 4)
                    }
                } footer: {
                    Text(L("只列出已经安装的语音工具。其他输入法或 app 可以在配置文件里写 voiceInput。", "Only installed voice tools are listed. Others can be set as voiceInput in the config file."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }.frame(width: 520).fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        VStack(spacing: 0) {
            ErrorBanner(store: store)
            Form {
                Section {
                    LabeledContent(L("辅助功能权限", "Accessibility")) {
                        if store.trusted {
                            Label(L("已允许", "Allowed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button(L("去允许…", "Allow…")) {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                        }
                    }
                }
                Section {
                    Toggle(L("开机启动", "Open at Login"), isOn: Binding(get: { store.launchAtLogin }, set: { on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                        store.refresh()
                    }))
                    Toggle(L("在菜单栏显示图标", "Show in Menu Bar"), isOn: Binding(get: { store.showMenuBarIcon }, set: { v in store.edit { $0.showMenuBarIcon = v } }))
                    Toggle(L("在 Dock 显示图标", "Show in Dock"), isOn: Binding(get: { store.showDockIcon }, set: { v in store.edit { $0.showDockIcon = v } }))
                    if !store.showMenuBarIcon && !store.showDockIcon {
                        Text(L("两个图标都关了：再次打开 Hijack 就能回到这里。", "Both icons off: open Hijack again to come back here."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Picker(L("语言", "Language"), selection: Binding(get: { store.language }, set: { v in store.edit { $0.language = v } })) {
                        Text(L("跟随系统", "System")).tag("system"); Text("English").tag("en"); Text("中文").tag("zh")
                    }
                }
                Section {
                    LabeledContent(L("配置文件", "Config file")) {
                        HStack {
                            Text("~/.config/hijack/config.json").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Button(L("在编辑器中打开", "Open in Editor")) { (NSApp.delegate as? AppDelegate)?.openConfig() }
                        }
                    }
                }
            }.formStyle(.grouped)
        }.frame(width: 520).fixedSize(horizontal: false, vertical: true)
    }
}

struct AdvancedTab: View {
    @ObservedObject var store: SettingsStore
    func row(_ title: String, _ hint: String, _ value: Double, range: ClosedRange<Double>, step: Double, set: @escaping (Config, Double) -> Void) -> some View {
        LabeledContent {
            Stepper(value: Binding(get: { value }, set: { v in store.edit { set($0, (v * 100).rounded() / 100) } }), in: range, step: step) {
                Text(String(format: L("%.2g 秒", "%.2g s"), value)).monospacedDigit()
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) { Text(title); Text(hint).font(.footnote).foregroundStyle(.secondary) }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            ErrorBanner(store: store)
            Form {
                Section {
                    row(L("按住多久才开始", "Hold before starting"), L("太短容易误触发", "Shorter means more accidental starts"), store.holdDelay, range: 0.05...1, step: 0.05) { $0.holdDelay = $1 }
                    row(L("最多等它上屏", "Longest wait for the text"), L("说长段话时可以调大", "Raise it for long dictations"), store.restoreTimeout, range: 1...15, step: 0.5) { $0.restoreTimeout = $1 }
                    row(L("看不到它的窗口时等待", "Wait when its window can't be seen"), L("用于不显示窗口的语音工具", "For voice tools that show no window"), store.fallbackDelay, range: 0.5...10, step: 0.5) { $0.fallbackDelay = $1 }
                }
                Section {
                    LabeledContent(L("日志", "Log")) {
                        Button(L("在访达中显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
                    }
                }
            }.formStyle(.grouped)
        }.frame(width: 520).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: window — toolbar tabs, like most Mac settings windows

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static var shared: SettingsWindowController?

    static func show() {
        let c = shared ?? SettingsWindowController()
        shared = c
        SettingsStore.shared.refresh()
        NSApp.activate(ignoringOtherApps: true)      // accessory apps otherwise open it behind other windows
        c.window?.makeKeyAndOrderFront(nil)
    }

    convenience init() {
        let store = SettingsStore.shared
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func tab<V: View>(_ title: String, _ symbol: String, _ view: V) -> NSTabViewItem {
            let host = NSHostingController(rootView: view)
            host.title = title                       // the window title follows the selected tab
            if #available(macOS 13.0, *) { host.sizingOptions = .preferredContentSize }
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }
        tabs.addTabViewItem(tab(L("听写", "Dictation"), "mic", DictationTab(store: store)))
        tabs.addTabViewItem(tab(L("语音来源", "Sources"), "waveform", SourcesTab(store: store)))
        tabs.addTabViewItem(tab(L("通用", "General"), "gearshape", GeneralTab(store: store)))
        tabs.addTabViewItem(tab(L("高级", "Advanced"), "slider.horizontal.3", AdvancedTab(store: store)))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = appName
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        window.center()
    }

    func windowWillClose(_ n: Notification) { SettingsStore.shared.stopRecording() }
}
