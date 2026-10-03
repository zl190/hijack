import Foundation

/// What `hijack version` says about an update. The input is what Sparkle stored after its last check
/// (SULatestAppcastItemFound, SUSkippedVersion); the CLI makes no network call.
enum UpdateNotice {
    /// nil: nothing to say. Otherwise one short line for the CLI.
    static func line(running: String, found: String?, skipped: String?) -> String? {
        guard let found, compare(found, running) == .orderedDescending else { return nil }
        return "update available: \(found)" + (skipped == found ? " (skipped)" : "")
    }

    /// Numeric, component by component; a missing component counts as 0 ("1.2" == "1.2.0").
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
