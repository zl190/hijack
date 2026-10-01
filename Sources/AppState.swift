import AppKit

// MARK: app state — what the running app knows that a CLI process can't check itself
// (Accessibility is granted to the app, not to the terminal running `hijack`).
// ~/Library/Application Support/Hijack/state.json, rewritten whenever it changes.

let stateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Hijack/state.json")

struct AppState: Codable {
    var pid: Int32
    var trusted: Bool          // Accessibility granted to the app
    var tapActive: Bool        // the key listener is installed
    var updated: Date

    static func write(trusted: Bool, tapActive: Bool) {
        let s = AppState(pid: getpid(), trusted: trusted, tapActive: tapActive, updated: Date())
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
