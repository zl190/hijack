import HijackCore
import AppKit
import ApplicationServices
import ServiceManagement
import Sparkle
import SwiftUI

// MARK: settings window — a view of ~/.config/hijack/config.json (the file stays the source of truth).
// Every change is written to the file at once; hand edits show up within a second.

enum RecordTarget: Equatable {
    case trigger
    case voiceKey(String)
}

struct SourceRow: Identifiable {
    let id: String, name: String
    let detectedKey: KeySpec?, userKey: KeySpec?, readsSettings: Bool
    let style: String, styleIsSet: Bool
}

final class SettingsStore: ObservableObject {
    static let shared: SettingsStore = SettingsStore()

    @Published var triggerMode: String = "hold"
    @Published var stopOnAnyKey: Bool = true
    @Published var trigger: KeySpec?
    @Published var voiceInput: String = ""
    @Published var sources: [SourceRow] = []
    @Published var showMenuBarIcon: Bool = true
    @Published var showDockIcon: Bool = false
    @Published var launchAtLogin: Bool = false
    @Published var language: String = "system"
    @Published var holdDelay: Double = 0.2
    @Published var restoreTimeout: Double = 5.0
    @Published var fallbackDelay: Double = 2.5
    @Published var trusted: Bool = false
    @Published var configError: String?
    @Published var recording: RecordTarget?
    @Published var live: String = ""  // what the engine is doing right now
    @Published var last: String = ""  // how the last dictation went

    private var timer: Timer?
    /// While the window is open: Accessibility permission and the running state have no file to watch.
    func startLive() {
        timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stopLive() { timer?.invalidate(); timer = nil }
    private var monitor: Any?

    init() {
        refresh()
        NotificationCenter.default.addObserver(forName: .hijackSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        NotificationCenter.default.addObserver(forName: .hijackActivity, object: nil, queue: .main) { [weak self] n in
            let phase = n.userInfo?["phase"] as? String ?? "", detail = n.userInfo?["detail"] as? String ?? ""
            switch phase {
            case "switching": self?.live = L("切到\(detail)…", "Switching to \(detail)…")
            case "listening": self?.live = L("正在听…", "Listening…")
            // FM-09: the voice tool's own mic has read "off" for 1s while the key is held (Engine.sampleWhileHeld).
            case "notListening": self?.live = L("\(detail)还没开始听…", "\(detail) isn't listening yet…")
            case "finishing": self?.live = L("说完了，等文字上屏…", "Done talking, waiting for the text…")
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
        configError = c.errorText
        launchAtLogin = SMAppService.mainApp.status == .enabled
        trusted = AXIsProcessTrusted()
        var rows = installedProviders()
        if !rows.contains(where: { $0.id == c.voiceInput }) { rows.append(voiceProvider(for: c.voiceInput)) }
        sources = rows.map { p in
            let d = p.detected()
            return SourceRow(
                id: p.id, name: p.name, detectedKey: d.key, userKey: c.voiceKeys[p.id], readsSettings: p.readsSettings,
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
        // Otherwise pressing the current trigger would start a dictation. Review-5 #8: paused clears on
        // its own after Engine.recordingPauseTimeout (30s) if this recording is never finished or cancelled
        // (switching apps, say), so dictation cannot stay dead with no signal why.
        engine?.pauseForKeyRecording()
        var downModifier: Int?, sawOtherKey = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self, let target = self.recording else { return e }
            if e.type == .keyDown {
                sawOtherKey = true
                // Esc with no modifier cancels the recording.
                if e.keyCode == 53 && e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { self.stopRecording(); return nil }
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
            if isDown {
                downModifier = code; sawOtherKey = false
            } else if downModifier == code && !sawOtherKey {
                self.finish(target, KeySpec(code: code))
            }
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
        monitor = nil; recording = nil; engine?.resumeFromKeyRecording()
    }
}

// MARK: views

struct KeyRecorder: View {
    @ObservedObject var store: SettingsStore
    let target: RecordTarget
    let key: KeySpec
    var body: some View {
        let on = store.recording == target
        Button {
            on ? store.stopRecording() : store.startRecording(target)
        } label: {
            Text(on ? L("按下想用的键…（Esc 取消）", "Press a Key… (Esc Cancels)") : key.name)
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 96).padding(.horizontal, 8).frame(height: 22)
                .foregroundStyle(on ? Color.accentColor : .primary)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.18)))
        }.buttonStyle(.plain)
    }
}

// MARK: Liquid Glass layout — a blurred-desktop window background with glass cards on top

/// The desktop behind the window, blurred: glass needs something underneath to refract.
struct WindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground; v.blendingMode = .behindWindow; v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// A titled group of rows on one glass card.
struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 6) }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)  // every card spans the page, whatever its content
                .padding(.horizontal, 14).padding(.vertical, 4)
                .modifier(GlassCard())
        }
    }
}

/// One row: title (and optional hint) on the left, control on the right; rows inside a card are divided.
struct Row<Trailing: View>: View {
    let title: String
    var hint: String? = nil
    var divider: Bool = true
    @ViewBuilder let trailing: Trailing
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let hint { Text(hint).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                trailing
            }.padding(.vertical, 9)
            if divider { Divider().opacity(0.5) }
        }
    }
}

/// The page every tab sits on.
struct Page<Content: View>: View {
    @ObservedObject var store: SettingsStore
    @ViewBuilder let content: Content
    var body: some View {
        let stack = VStack(alignment: .leading, spacing: 16) {
            if let e = store.configError {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.85)))
            }
            content
        }.padding(20)
        Group {
            if #available(macOS 26.0, *) { GlassEffectContainer(spacing: 16) { stack } } else { stack }
        }
        .frame(width: 520).fixedSize(horizontal: false, vertical: true)
        .background(WindowBlur().ignoresSafeArea())
    }
}

/// One option of a single choice, as a full-width row: icon, title, a line of explanation, ✓ when chosen.
struct ChoiceRow: View {
    let icon: String, title: String
    var detail: String? = nil
    let selected: Bool
    var divider: Bool = true
    let action: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: icon).font(.title3).frame(width: 26).foregroundStyle(selected ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if selected { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accentColor) }
                }.padding(.vertical, 9).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            if divider { Divider().opacity(0.5) }
        }
    }
}

let accessibilityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

struct DictationTab: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        Page(store: store) {
            Card(title: L("听写方式", "How You Dictate")) {
                ChoiceRow(
                    icon: "hand.raised", title: L("按住说话", "Hold to Talk"), detail: L("按住说，松开停", "Hold the key while you speak"),
                    selected: store.triggerMode == "hold"
                ) { store.edit { $0.triggerMode = "hold" } }
                ChoiceRow(
                    icon: "hand.tap", title: L("点按开始，再点停止（免按）", "Tap to Start, Tap to Stop"),
                    detail: L("点一下开始，再点一下停止", "Tap once to start, again to stop"),
                    selected: store.triggerMode == "toggle", divider: store.triggerMode == "toggle"
                ) { store.edit { $0.triggerMode = "toggle" } }
                if store.triggerMode == "toggle" {
                    Row(title: L("按任意键也可停止", "Any Key Also Stops"), divider: false) {
                        Toggle("", isOn: Binding(get: { store.stopOnAnyKey }, set: { v in store.edit { $0.stopOnAnyKey = v } }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
            }
            Card(title: L("快捷键", "Shortcut")) {
                Row(
                    title: L("按这个键听写", "Key you press"),
                    hint: store.trigger == nil ? L("同\(store.currentName)里的说话键", "Same as \(store.currentName)'s talk key") : nil,
                    divider: store.trigger != nil
                ) {
                    KeyRecorder(store: store, target: .trigger, key: store.effectiveTrigger)
                }
                if store.trigger != nil {
                    Row(title: L("改回同说话键（\(store.model.forwardKey.name)）", "Use Talk Key (\(store.model.forwardKey.name))"), divider: false)
                    {
                        Button(L("改回", "Reset")) { store.edit { $0.trigger = nil } }
                    }
                }
                if let t = store.trigger, !t.modifierOnly, t.mods.isEmpty, t.code < 96 {
                    Label(
                        L("单独一个普通键当快捷键，平时打字按到它也会触发", "A plain key alone also triggers while you type"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout).foregroundStyle(.orange).padding(.vertical, 8)
                }
            }
            Card(title: L("试一下", "Try It")) {
                if MenuFaults.showsStaleAccessibilityGuidance(trusted: store.trusted) {
                    Row(title: L("辅助功能未生效", "Accessibility isn't working"), hint: staleAccessibilityGuidance) {
                        Button(L("去系统设置…", "Open System Settings…")) {
                            if let accessibilityURL { NSWorkspace.shared.open(accessibilityURL) }
                        }
                    }
                }
                HStack(spacing: 12) {
                    if store.live.isEmpty {
                        Image(systemName: "mic").font(.title3).foregroundStyle(.secondary).frame(width: 28)
                    } else {
                        Bars(live: store.live == L("正在听…", "Listening…")).frame(width: 28)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            store.live.isEmpty
                                ? (store.triggerMode == "toggle"
                                    ? L(
                                        "点按\(store.effectiveTrigger.name)，说一句，再点一下",
                                        "Tap \(store.effectiveTrigger.name), say something, tap again")
                                    : L("按住\(store.effectiveTrigger.name)说一句", "Hold \(store.effectiveTrigger.name) and say something"))
                                : store.live)
                        if !store.last.isEmpty { Text(store.last).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Spacer()
                }.padding(.vertical, 12)
            }
        }
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
    @State private var showStyle = false
    let styleNames = ["hold": L("按住", "Hold"), "tap": L("单击", "Single Tap"), "doubleTap": L("双击", "Double Tap")]
    var body: some View {
        Page(store: store) {
            if store.sources.isEmpty {
                Card {
                    Text(
                        L(
                            "没有找到已安装的语音工具。支持：微信输入法、豆包输入法、搜狗输入法、Handy。",
                            "No supported voice tool is installed. Supported: WeType, Doubao, Sogou, Handy.")
                    )
                    .foregroundStyle(.secondary).padding(.vertical, 12)
                }
            } else {
                Card(title: L("语音来源", "Voice Source")) {
                    ForEach(Array(store.sources.enumerated()), id: \.element.id) { i, src in
                        ChoiceRow(
                            icon: src.id.hasPrefix("app:") ? "app" : "keyboard", title: src.name,
                            detail: src.id.hasPrefix("app:")
                                ? L("听写 app，Hijack 替你按它的快捷键", "Dictation app; Hijack presses its hotkey")
                                : L("输入法，Hijack 切过去用完再切回", "Input method; Hijack switches to it and back"),
                            selected: src.id == store.voiceInput, divider: i < store.sources.count - 1
                        ) { store.edit { $0.voiceInput = src.id } }
                    }
                }
                if let s = store.sources.first(where: { $0.id == store.voiceInput }) {
                    Card(title: L("\(s.name)的设置", s.name)) {
                        Row(
                            title: L("说话键", "Talk Key"),
                            hint: L(
                                "\(s.name)在它自己的设置里用来说话的键，Hijack 会替你按它",
                                "The key \(s.name) uses for talking, set in its own settings; Hijack presses it for you")
                        ) {
                            VStack(alignment: .trailing, spacing: 4) {
                                // "right_option" is a literal id in namedKeys; see KeysTests.testW5_QuickKeysAlwaysResolveToANamedKey.
                                // swift-format-ignore: NeverForceUnwrap
                                KeyRecorder(
                                    store: store, target: .voiceKey(s.id), key: s.userKey ?? s.detectedKey ?? KeySpec.named("right_option")!
                                )
                                if s.userKey != nil {
                                    Button(L("恢复自动检测", "Use Auto-Detect")) { store.edit { $0.voiceKeys[s.id] = nil } }.buttonStyle(.link)
                                        .font(.footnote)
                                } else {
                                    Text(
                                        s.detectedKey == nil
                                            ? L("⚠︎ 没读到，请录制", "⚠︎ Not found — record it")
                                            : s.readsSettings ? L("自动检测", "Auto-Detected") : L("默认值，未验证", "Default, Unverified")
                                    )
                                    .font(.footnote).foregroundStyle(s.detectedKey == nil || !s.readsSettings ? Color.orange : .secondary)
                                }
                            }
                        }
                        if s.style != "hold" || s.styleIsSet || showStyle {
                            Row(title: L("启动方式", "Starts With"), divider: false) {
                                Picker("", selection: Binding(get: { s.style }, set: { v in store.edit { $0.voiceStyles[s.id] = v } })) {
                                    ForEach(["hold", "tap", "doubleTap"], id: \.self) { Text(styleNames[$0] ?? $0).tag($0) }
                                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                            }
                        } else {
                            Button(L("它不支持按住说话？更改启动方式…", "Doesn't support hold-to-talk? Change how it starts…")) { showStyle = true }
                                .buttonStyle(.link).font(.callout).padding(.vertical, 10)
                        }
                    }
                }
                Text(L("只列出已安装的语音工具；其他的可以写进配置文件。", "Only installed voice tools are listed; others can go in the config file."))
                    .font(.footnote).foregroundStyle(.secondary).padding(.leading, 6)
            }
        }
    }
}

/// In-app updates: two Sparkle settings and a manual check. Sparkle stores both values itself.
struct UpdatesCard: View {
    private var updater: SPUUpdater? { (NSApp.delegate as? AppDelegate)?.updater?.updater }
    @State private var checksAutomatically = true
    @State private var downloadsAutomatically = false
    var body: some View {
        Card(title: L("更新", "Updates")) {
            if updater == nil {
                Row(title: L("当前版本", "Version"), hint: appVersion, divider: false) {
                    Text(noUpdateKeyText).font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Row(
                    title: L("自动检查更新", "Check for Updates Automatically"),
                    hint: L("每天一次，发现新版本会先问你", "Once a day. Sparkle asks before it installs")
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { checksAutomatically },
                            set: { v in
                                updater?.automaticallyChecksForUpdates = v; checksAutomatically = v
                            })
                    ).toggleStyle(.switch).labelsHidden()
                }
                Row(title: L("自动下载并安装", "Download and Install Automatically")) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { downloadsAutomatically },
                            set: { v in
                                updater?.automaticallyDownloadsUpdates = v; downloadsAutomatically = v
                            })
                    ).toggleStyle(.switch).labelsHidden()
                }
                Row(title: L("当前版本", "Version"), hint: appVersion, divider: false) {
                    Button(L("现在检查", "Check Now")) { updater?.checkForUpdates() }
                }
            }
        }
        .onAppear {
            checksAutomatically = updater?.automaticallyChecksForUpdates ?? true
            downloadsAutomatically = updater?.automaticallyDownloadsUpdates ?? false
        }
    }
}

struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        Page(store: store) {
            Card {
                Row(title: L("辅助功能权限", "Accessibility"), divider: false) {
                    if store.trusted {
                        Label(L("已允许", "Allowed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(L("去允许…", "Allow…")) { if let accessibilityURL { NSWorkspace.shared.open(accessibilityURL) } }
                    }
                }
            }
            Card {
                Row(title: L("开机启动", "Open at Login")) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { store.launchAtLogin },
                            set: { on in
                                if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                                store.refresh()
                            })
                    ).toggleStyle(.switch).labelsHidden()
                }
                Row(title: L("在菜单栏显示图标", "Show in Menu Bar")) {
                    Toggle("", isOn: Binding(get: { store.showMenuBarIcon }, set: { v in store.edit { $0.showMenuBarIcon = v } }))
                        .toggleStyle(.switch).labelsHidden()
                }
                Row(
                    title: L("在 Dock 显示图标", "Show in Dock"),
                    hint: !store.showMenuBarIcon && !store.showDockIcon
                        ? L("两个图标都关了：再次打开 Hijack 就能回到这里", "Both icons off: open Hijack again to come back here") : nil
                ) {
                    Toggle("", isOn: Binding(get: { store.showDockIcon }, set: { v in store.edit { $0.showDockIcon = v } })).toggleStyle(
                        .switch
                    ).labelsHidden()
                }
                Row(title: L("语言", "Language"), divider: false) {
                    Picker("", selection: Binding(get: { store.language }, set: { v in store.edit { $0.language = v } })) {
                        Text(L("跟随系统", "System")).tag("system"); Text("English").tag("en"); Text("中文").tag("zh")
                    }.labelsHidden().frame(width: 130)
                }
            }
            UpdatesCard()
            Card {
                Row(title: L("配置文件", "Config File"), hint: "~/.config/hijack/config.json", divider: false) {
                    Button(L("在编辑器中打开", "Open in Editor")) { (NSApp.delegate as? AppDelegate)?.openConfig() }
                }
            }
        }
    }
}

struct AdvancedTab: View {
    @ObservedObject var store: SettingsStore
    func stepper(_ value: Double, range: ClosedRange<Double>, step: Double, set: @escaping (Config, Double) -> Void) -> some View {
        Stepper(value: Binding(get: { value }, set: { v in store.edit { set($0, (v * 100).rounded() / 100) } }), in: range, step: step) {
            Text(String(format: L("%.2g 秒", "%.2g s"), value)).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }
    var body: some View {
        Page(store: store) {
            Card {
                // Ranges shared with Config's load-time clamp and CLI.swift's `hijack set` (review-4 S5,
                // Sources/Core/ConfigValues.swift): one source of truth for all three entry points.
                Row(title: L("按住多久才开始", "Hold before starting"), hint: L("太短容易误触发", "Shorter means more accidental starts")) {
                    stepper(store.holdDelay, range: holdDelayRange, step: 0.05) { $0.holdDelay = $1 }
                }
                Row(title: L("最多等文字上屏", "Longest wait for the text"), hint: L("说长段话时可以调大", "Raise it for long dictations")) {
                    stepper(store.restoreTimeout, range: restoreTimeoutRange, step: 0.5) { $0.restoreTimeout = $1 }
                }
                Row(
                    title: L("语音工具没有窗口时等待", "Wait when the voice tool shows no window"),
                    hint: L("看不到它何时上屏完，就固定等这么久", "Hijack can't tell when it's done, so it waits this long"), divider: false
                ) {
                    stepper(store.fallbackDelay, range: fallbackDelayRange, step: 0.5) { $0.fallbackDelay = $1 }
                }
            }
            Card {
                Row(title: L("日志", "Log"), hint: "~/Library/Logs/Hijack.log", divider: false) {
                    Button(L("在访达中显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
                }
            }
        }
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static var shared: SettingsWindowController?

    static func show(tab: Int? = nil) {
        let c = shared ?? SettingsWindowController()
        shared = c
        if let tab, let tabs = c.window?.contentViewController as? NSTabViewController { tabs.selectedTabViewItemIndex = tab }
        SettingsStore.shared.refresh(); SettingsStore.shared.startLive()
        NSApp.activate(ignoringOtherApps: true)  // accessory apps otherwise open it behind other windows
        c.window?.makeKeyAndOrderFront(nil)
    }

    convenience init() {
        let store = SettingsStore.shared
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func tab<V: View>(_ title: String, _ symbol: String, _ view: V) -> NSTabViewItem {
            let host = NSHostingController(rootView: view)
            if #available(macOS 13.0, *) { host.sizingOptions = .preferredContentSize }
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }
        tabs.addTabViewItem(tab(L("听写", "Dictation"), "mic", DictationTab(store: store)))
        tabs.addTabViewItem(tab(L("语音来源", "Voice Source"), "waveform", SourcesTab(store: store)))
        tabs.addTabViewItem(tab(L("通用", "General"), "gearshape", GeneralTab(store: store)))
        tabs.addTabViewItem(tab(L("高级", "Advanced"), "slider.horizontal.3", AdvancedTab(store: store)))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        tabs.canPropagateSelectedChildViewControllerTitle = false  // keep one title; the toolbar shows the tab
        window.title = L("\(appName) 设置", "\(appName) Settings")
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        window.center()
    }

    func windowWillClose(_ n: Notification) { SettingsStore.shared.stopRecording(); SettingsStore.shared.stopLive() }
}
