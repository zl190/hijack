import Foundation

// MARK: the key-listener chain (W10, docs/adr/0023). Pure: the app hands in the system's tap list as rows, with
// name and start-time lookups injected, and gets back who sits ahead of our listener. Tested without the window server.

/// One row of the system's event-tap list, reduced to what the chain read needs.
public struct TapRow: Equatable {
    public var pid: pid_t
    public var hidLevel: Bool  // tapped at the HID level (where ours is); session-level taps run after every HID tap
    public var enabled: Bool
    public var filtering: Bool  // a filtering tap can swallow an event; a listen-only one cannot
    public var watchesFlags: Bool  // its mask has flagsChanged (a modifier talk key such as Fn is one)
    public var watchesKeys: Bool  // its mask has keyDown or keyUp (a plain talk key)
    public init(pid: pid_t, hidLevel: Bool, enabled: Bool, filtering: Bool, watchesFlags: Bool, watchesKeys: Bool) {
        self.pid = pid; self.hidLevel = hidLevel; self.enabled = enabled; self.filtering = filtering
        self.watchesFlags = watchesFlags; self.watchesKeys = watchesKeys
    }
}

/// What the read found. `ahead([])`: ours is first. `notListed`: our pid has no enabled tap for the talk key's event at the
/// HID level (the app is between restarts, or macOS turned the listener off). `unreadable`: the list itself could not be read.
public enum KeyListenerChain: Equatable {
    case unreadable
    case notListed
    case ahead([String])
}

/// The processes whose enabled, filtering taps for the talk key's event type at the HID level are listed before ours,
/// and that started before we did. The list is newest-first for taps pushed to the head, so an older process listed
/// before us re-created its tap after ours appeared: the pattern that puts it ahead again after any restart of ours.
/// A younger process ahead of us is ordinary creation order; a relaunch puts us back in front of it, so it is not named.
/// Names are made safe for the log line (`+`, `,` and `|` become `_`; a name equal to a field token gets a `_`).
/// `startedBeforeUs(pid)`: nil when unknown, which counts as older (a reader sees the name and judges).
public func keyListenerChain(
    rows: [TapRow], ours: pid_t, modifierKey: Bool, name: (pid_t) -> String, startedBeforeUs: (pid_t) -> Bool?
) -> KeyListenerChain {
    let relevant = rows.filter { $0.hidLevel && $0.enabled && (modifierKey ? $0.watchesFlags : $0.watchesKeys) }
    guard let ourIndex = relevant.firstIndex(where: { $0.pid == ours }) else { return .notListed }
    var names: [String] = []
    for row in relevant.prefix(ourIndex) where row.filtering && row.pid != ours && startedBeforeUs(row.pid) != false {
        let n = safeListenerName(name(row.pid))
        if !names.contains(n) { names.append(n) }
    }
    return .ahead(names)
}

/// A process name as the `ahead:` field can carry it: no field separators, never one of the field's own tokens.
public func safeListenerName(_ raw: String) -> String {
    var n = raw.map { "+,|".contains($0) ? "_" : $0 }.reduce(into: "") { $0.append($1) }
    if n.isEmpty || n == "none" || n == "?" { n += "_" }
    return n
}
