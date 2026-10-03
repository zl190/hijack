// MARK: menu state — pure decisions for the status item icon and the menu's first line.
// Kept in Core so the HCI review's fault-line choices (docs/hci-review-faults.md §3.1, §3.2) are unit-testable
// without AppKit. The app (Sources/Menu.swift) reads live facts, calls these, and renders the result.

/// The status item icon. Two states only: a third "Active" state was ruled out in the review (§5a item 2)
/// because changing the icon on every talk-key edge adds main-thread work (FM-26).
enum IconState: Equatable {
    case idle   // key listener on, Accessibility granted
    case off    // key listener off, or Accessibility missing (FM-02, FM-24 revoked while running)

    static func of(trusted: Bool, tapActive: Bool) -> IconState { (trusted && tapActive) ? .idle : .off }
}

/// One fault the menu can show as its first line, in place of the normal status line. Only one shows at a
/// time.
enum MenuFault: Equatable {
    case keyListenerOff
    case stillHolding(talkKey: String)   // a session the engine thinks is active, with the physical key already up
    case secureInput(app: String)
}

enum MenuFaults {
    /// `tapActive` false wins first (nothing works until it's fixed). Then a stuck session, which traps the
    /// user's next press. Then Secure Input, which only blocks the next dictation.
    static func firstLine(tapActive: Bool, stillHoldingTalkKey: String? = nil, secureInputApp: String? = nil) -> MenuFault? {
        if !tapActive { return .keyListenerOff }
        if let talkKey = stillHoldingTalkKey { return .stillHolding(talkKey: talkKey) }
        if let app = secureInputApp { return .secureInput(app: app) }
        return nil
    }
}
