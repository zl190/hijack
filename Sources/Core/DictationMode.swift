// MARK: dictation mode — what `triggerMode: "auto"` resolves to (docs/adr/0025-auto-mode.md).
// Pure, so the rule is unit-testable; the app reads the voice tool's version and passes it in.

public enum DictationMode {
    public static let explicit = ["hold", "toggle", "follow"]
    public static let all = ["auto"] + explicit

    /// Anything that is not an explicit mode counts as auto (a missing key, "auto", an unknown value).
    public static func isAuto(_ configured: String) -> Bool { !explicit.contains(configured) }

    /// The mode the engine runs in. `auto` picks follow for a tool that takes its own talk key (it starts on the
    /// physical key and ignores a posted one, so hold mode's post would be swallowed), hold otherwise. A configured
    /// hold / toggle / follow is returned as is.
    public static func resolve(configured: String, toolTakesTalkKey: Bool) -> String {
        isAuto(configured) ? (toolTakesTalkKey ? "follow" : "hold") : configured
    }

    /// WeType takes the talk key itself from 3.0.0 (build 670, installed on this Mac 2026-10-17): its exclusive-mode
    /// key listener sits ahead of ours and swallows a physical Fn, and it ignores a posted one (ADR 0023, 0024). 2.2.3
    /// was the last version where hold mode worked. Version sniffing, not feature detection: whether a key is swallowed
    /// can only be seen during a dictation, so the version decides up front and the dictation line is the evidence after.
    public static let weTypeTakesTalkKeyFrom = "3.0.0"
    public static func weTypeTakesTalkKey(version: String?) -> Bool {
        guard let version else { return false }
        return compareVersions(version, weTypeTakesTalkKeyFrom) >= 0
    }

    /// Dotted numeric compare; a missing component is 0, a non-numeric one is 0 too ("3.0.0" == "3" == "3.0.x").
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}
