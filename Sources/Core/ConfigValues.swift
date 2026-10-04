import Foundation

// MARK: config values — pure helpers Config.swift (outside this package's test target) builds on, so the
// risky parts of reading and writing ~/.config/hijack/config.json by hand are covered by tests (review-5 #14).

/// A JSON value rendered as text, through JSONSerialization, so a string is escaped correctly (quotes,
/// backslashes, control characters). Config.swift used to hand-build a string literal as `"\"\(s)\""`:
/// a value with a quote in it (`hijack set source 'a"b'`) wrote invalid JSON, and the next reload()
/// then refused every later save() (its own "don't overwrite an error" guard).
public func jsonLiteral(_ v: Any) -> String {
    if let b = v as? Bool { return b ? "true" : "false" }
    if let x = v as? Double { return String(format: "%g", x) }
    guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .fragmentsAllowed]) else { return "null" }
    return String(data: d, encoding: .utf8) ?? "null"
}

// Sane ranges for the three timing settings, shared by CLI.swift's `hijack set` validation and Config's
// own load-time clamp below (one source of truth for both paths into these values).
public let holdDelayRange = 0.05...1.0
public let restoreTimeoutRange = 1.0...15.0
public let fallbackDelayRange = 0.5...10.0

/// Clamp a loaded timing value into `range`, pairing it with a log line when it had to clamp (nil when
/// already in range). A hand edit of config.json bypasses `hijack set`'s own validation (CLI.swift), so
/// loading must not trust it: an absurd value (a 10-minute restoreTimeout) is clamped, not honored.
public func clampedTiming(_ value: Double, to range: ClosedRange<Double>, name: String) -> (value: Double, logLine: String?) {
    let clamped = min(max(value, range.lowerBound), range.upperBound)
    guard clamped != value else { return (value, nil) }
    return (clamped, "config: \(name) \(value) out of range \(range), clamped to \(clamped)")
}
