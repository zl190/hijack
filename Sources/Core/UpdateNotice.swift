import Foundation

/// The update the app recorded at its last Sparkle check. `display` is the short version string the user
/// sees; `build` is the appcast's sparkle:version, which Sparkle uses when the user skips a version.
public struct UpdateFound: Equatable {
    public var display: String
    public var build: String
    public init(display: String, build: String) { self.display = display; self.build = build }

    /// The user-defaults key the app writes (Sparkle itself stores no found update). Value: a dictionary
    /// with "display", "build" and "foundAt".
    public static let defaultsKey = "HijackUpdateFound"
    public init?(defaults d: [String: Any]?) {
        guard let d, let display = d["display"] as? String, let build = d["build"] as? String else { return nil }
        self.init(display: display, build: build)
    }
    public var asDefaults: [String: Any] { ["display": display, "build": build, "foundAt": Date()] }
}

/// What `hijack version` says about an update. The CLI makes no network call.
enum UpdateNotice {
    /// nil: nothing to say. Otherwise one short line for the CLI.
    static func line(running: String, found: UpdateFound?, skippedBuild: String?) -> String? {
        guard let found, compare(found.display, running) == .orderedDescending else { return nil }
        return "update available: \(found.display)" + (skippedBuild == found.build ? " (skipped)" : "")
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
