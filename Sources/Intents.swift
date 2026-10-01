import AppIntents
import AppKit

// MARK: App Intents — Hijack's actions for Shortcuts, Spotlight and Siri (the same settings the CLI changes).
// The build extracts their metadata (Metadata.appintents) so the system can find them without an Xcode project.

struct VoiceSourceEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Voice Source"
    static var defaultQuery = VoiceSourceQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct VoiceSourceQuery: EntityQuery {
    func all() -> [VoiceSourceEntity] { installedProviders().map { VoiceSourceEntity(id: $0.id, name: $0.name) } }
    func entities(for identifiers: [String]) async throws -> [VoiceSourceEntity] { all().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [VoiceSourceEntity] { all() }
}

enum DictationModeEnum: String, AppEnum {
    case hold, toggle
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Dictation Mode"
    static var caseDisplayRepresentations: [DictationModeEnum: DisplayRepresentation] = [
        .hold: "Hold to Talk",
        .toggle: "Tap to Start, Tap to Stop",
    ]
}

struct SetVoiceSourceIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Voice Source"
    static var description = IntentDescription("Choose which voice tool Hijack dictates with.")
    @Parameter(title: "Voice Source") var source: VoiceSourceEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = Config.shared; c.reload(force: true); c.voiceInput = source.id; c.save()
        log("intent: voice source \(source.id)")
        return .result(dialog: "Hijack now dictates with \(source.name).")
    }
}

struct SetDictationModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Dictation Mode"
    static var description = IntentDescription("Hold to talk, or tap to start and tap again to stop.")
    @Parameter(title: "Mode") var mode: DictationModeEnum

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = Config.shared; c.reload(force: true); c.triggerMode = mode.rawValue; c.save()
        log("intent: mode \(mode.rawValue)")
        return .result(dialog: mode == .hold ? "Hold the shortcut to dictate." : "Tap the shortcut to start, tap again to stop.")
    }
}

struct GetHijackStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Hijack Status"
    static var description = IntentDescription("What Hijack dictates with, how, and whether it's ready.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let m = Model.shared, st = AppState.read()
        let ready = st?.trusted == true && st?.tapActive == true
        let text = "\(m.toggleMode ? "Tap" : "Hold") \(m.trigger.name) to dictate with \(m.voiceName)."
            + (ready ? "" : " Hijack isn't ready: " + (st == nil ? "it isn't running." : "it needs Accessibility permission."))
        return .result(value: text, dialog: "\(text)")
    }
}

struct HijackShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SetVoiceSourceIntent(),
                    phrases: ["Set \(.applicationName) voice source", "Dictate with \(\.$source) in \(.applicationName)"],
                    shortTitle: "Voice Source", systemImageName: "waveform")
        AppShortcut(intent: SetDictationModeIntent(),
                    phrases: ["Set \(.applicationName) dictation mode", "Switch \(.applicationName) to \(\.$mode)"],
                    shortTitle: "Dictation Mode", systemImageName: "hand.tap")
        AppShortcut(intent: GetHijackStatusIntent(),
                    phrases: ["\(.applicationName) status", "Is \(.applicationName) ready"],
                    shortTitle: "Status", systemImageName: "checkmark.circle")
    }
}
