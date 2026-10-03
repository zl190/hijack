import AppKit

// Which app is in front — for lining a dictation up with where the text went. NSWorkspace, not Accessibility:
// an AX query blocks while the target app is busy, and the key tap shares the main thread.
func frontApp() -> String { "front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")" }
