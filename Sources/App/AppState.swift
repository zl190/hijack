import HijackCore
import AppKit

// MARK: app state — what the running app knows that a CLI process can't check itself
// (Accessibility is granted to the app, not to the terminal running `hijack`).
// ~/Library/Application Support/Hijack/state.json, rewritten whenever it changes.

let stateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Hijack/state.json")

struct AppState: Codable {
    var pid: Int32
    var trusted: Bool  // Accessibility granted to the app
    var tapActive: Bool  // the key listener is installed
    // Secure Event Input, as of the last menu open or dictation summary (Sources/Menu.swift). It is not
    // pushed on every change: a CLI process can read it, but it can be stale between those two moments.
    var secureInput: Bool
    var secureInputApp: String?  // the frontmost app's name when secureInput was last true; nil otherwise
    var updated: Date

    init(pid: Int32, trusted: Bool, tapActive: Bool, secureInput: Bool, secureInputApp: String?, updated: Date) {
        self.pid = pid; self.trusted = trusted; self.tapActive = tapActive
        self.secureInput = secureInput; self.secureInputApp = secureInputApp; self.updated = updated
    }

    // A custom decoder: state.json from before 1.1.4 has no "secureInput" key, and must still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        trusted = try c.decode(Bool.self, forKey: .trusted)
        tapActive = try c.decode(Bool.self, forKey: .tapActive)
        secureInput = try c.decodeIfPresent(Bool.self, forKey: .secureInput) ?? false
        secureInputApp = try c.decodeIfPresent(String.self, forKey: .secureInputApp)
        updated = try c.decode(Date.self, forKey: .updated)
    }

    /// `secureInput` and `secureInputApp`: nil keeps the previous value on file, so a write that doesn't know
    /// about Secure Input (most of them — see the comment above) can't erase a value set elsewhere.
    static func write(trusted: Bool, tapActive: Bool, secureInput: Bool? = nil, secureInputApp: String? = nil) {
        let prior = read()
        let si = secureInput ?? prior?.secureInput ?? false
        let app = secureInput != nil ? secureInputApp : prior?.secureInputApp
        let s = AppState(pid: getpid(), trusted: trusted, tapActive: tapActive, secureInput: si, secureInputApp: app, updated: Date())
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(s).write(to: stateURL, options: .atomic)
    }

    /// The running app's state, or nil when Hijack isn't running (stale file from a dead process).
    static func read() -> AppState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let s = try? dec.decode(AppState.self, from: data), kill(s.pid, 0) == 0 else { return nil }
        return s
    }
}
