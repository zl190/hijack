import Foundation

// MARK: stats — "is it reliable?" answered from the log: one summary line per dictation (Engine.summary).
// Pure: takes log lines, returns numbers, so the tests can feed it real lines.

/// One dictation, as its summary line tells it.
public struct DictationEntry: Equatable {
    public enum Outcome: String, CaseIterable {
        case textArrived = "text arrived"  // the voice window came and went
        case noWindow = "no voice window"  // the talk key went out, but no window was seen
        case interrupted = "interrupted"  // the next press came before the text
        case unverified = "not watched"  // an app tool: its window isn't watched
        case tooShort = "too short to start"  // released before the talk key was sent
    }
    /// Why a dictation with no voice window failed, from the checks on its line.
    public enum Cause: String, CaseIterable {
        case keyNotSent = "talk key never went out (echo missing)"
        case takenAhead = "talk key taken by another app's key listener (echo missing, ahead: …)"
        case toolDidntListen = "voice tool didn't start listening (mic off)"
        case windowNotSeen = "tool listened, its window wasn't seen (mic on)"
        case unknown = "not enough checks on the line"
        case sourceNotSwitched = "input source never switched (talk key not sent)"
    }
    public var day: String  // yyyy-MM-dd
    public var tool: String
    public var toggle: Bool
    public var follow: Bool = false  // W11: the tool took its own physical key; nothing was posted (no sent/echo/ahead fields)
    public var heldMs: Int
    public var sentMs: Int?
    public var textInMs: Int?  // release → voice window gone
    public var outcome: Outcome
    public var cause: Cause?
    // W7, dropped on 2026-10-19 (older lines still carry it): the key state showed the talk key down (nil: no field).
    public var postSeen: Bool?
    public var echoSeen: Bool?  // our talk key came back through our own tap (nil: no echo field, or never sent)
    public var listenersAhead: [String]?  // W10: other processes' filtering key listeners ahead of ours (nil: `?` or no field)
    public var tapDisabled: Bool
    public var secureInput: Bool

    /// Parses a summary line written since 1.1.2 ("yyyy-MM-dd HH:mm:ss.SSS dictation …"); nil for any other line.
    public static func parse(_ line: String) -> DictationEntry? {
        guard line.count > 24, line.dropFirst(23).hasPrefix(" dictation "),
            line.prefix(4).allSatisfy(\.isNumber)
        else { return nil }
        func num(_ pattern: String) -> Double? {
            guard let r = try? Regex(pattern), let m = line.firstMatch(of: r), m.count > 1,
                let s = m[1].substring
            else { return nil }
            return Double(s)
        }
        func word(_ pattern: String) -> String? {
            guard let r = try? Regex(pattern), let m = line.firstMatch(of: r), m.count > 1, let s = m[1].substring else { return nil }
            return String(s)
        }
        guard let tool = word(#"dictation (.+?) \((?:hold|toggle|follow)\):"#) else { return nil }
        let modeWord = word(#"\((hold|toggle|follow)\): (?:held |switched in)"#)  // the mode word in its slot, not anywhere on the line
        let follow = modeWord == "follow"
        // W11: a follow dictation that began on the tool's own switch-in has no hold at all.
        guard let held = num(#"held ([\d.]+)s"#) ?? (follow && line.contains("switched in by the tool") ? 0 : nil) else { return nil }
        let sent = num(#"sent after (\d+)ms"#).map { Int($0) }
        let textIn = num(#"(?:window closed|mic off) (\d+)ms after (?:release|start)"#).map { Int($0) }
        let echo = line.contains("echo missing") ? false : line.contains("echo after") ? true : nil
        let post = line.contains("post: not seen") ? false : line.contains("post: seen") ? true : nil
        let ahead: [String]? = word(#"ahead: ([^,|]+)"#).flatMap { $0 == "?" ? nil : $0 == "none" ? [] : $0.components(separatedBy: "+") }
        let mic = word(#"mic tool (on|off)"#).map { $0 == "on" }
        let outcome: Outcome
        if line.contains("input source never switched") {
            outcome = .noWindow
        } else if line.contains("released before") || line.contains("left alone") || (sent == nil && !follow) {
            // W11: a follow line never has `sent`; it is judged on its window and mic unless it was no dictation
            // (`released before`, or a switch into the voice source with nothing live after it: `left alone`).
            outcome = .tooShort
        } else if line.contains("interrupted by the next press") || line.contains("the tool switched itself in") {
            outcome = .interrupted
        } else if textIn != nil {
            outcome = .textArrived
        } else if line.contains("no switch back needed") {
            outcome = .unverified
        } else {
            outcome = .noWindow
        }
        var cause: Cause?
        if outcome == .noWindow {
            cause =
                line.contains("input source never switched")
                ? .sourceNotSwitched
                : echo == false && ahead?.isEmpty == false
                    ? .takenAhead
                    : echo == false || (echo == nil && post == false)
                        ? .keyNotSent : mic == false ? .toolDidntListen : mic == true ? .windowNotSeen : .unknown
        }
        return DictationEntry(
            day: String(line.prefix(10)), tool: tool, toggle: modeWord == "toggle", follow: follow,
            heldMs: Int(held * 1000), sentMs: sent, textInMs: textIn, outcome: outcome, cause: cause,
            postSeen: post, echoSeen: echo, listenersAhead: ahead, tapDisabled: line.contains("key tap disabled"),
            secureInput: line.contains("secure input on"))
    }
}

/// The numbers for a set of dictations (and the incidents logged around them).
public struct DictationStats: Equatable {
    public var dictations: Int  // the talk key went out (too-short taps not counted)
    public var outcomes: [DictationEntry.Outcome: Int]
    public var causes: [DictationEntry.Cause: Int]
    public var tooShort: Int
    public var sentP50: Int?, sentP95: Int?
    public var textInP50: Int?, textInP95: Int?
    public var tapPaused: Int, slowKeys: Int, caughtUp: Int
    public var tools: [String: Int]
    public var firstDay: String?, lastDay: String?
    // W9: dictations with `nap: on|off`; of those, `nap: on`; of those, `echo missing`.
    public var nappedSampled: Int = 0, napped: Int = 0, nappedFailed: Int = 0
    public var selfRelaunches: Int = 0  // W8: `self-relaunch:` lines (the suppressed ones are not counted)
    public var manualRestarts: Int = 0  // `restart: ` lines: the menu's Restart Hijack and `hijack restart`
    // W10: dictations with an `ahead:` reading; of those, with another listener ahead; of those, `echo missing`.
    public var aheadSampled: Int = 0, listenerAhead: Int = 0, listenerAheadFailed: Int = 0
    public var followed: Int = 0  // W11: dictations in follow mode (nothing posted; judged on the voice window alone)

    /// Share of judged dictations (text arrived or no window) where the text arrived; nil when none were judged.
    public var successRate: Double? {
        let ok = outcomes[.textArrived, default: 0], judged = ok + outcomes[.noWindow, default: 0]
        return judged == 0 ? nil : Double(ok) / Double(judged)
    }

    /// The reliability bar `hijack stats` reports against. Provisional until 7 days of 1.2.x data are in;
    /// review it then.
    public static let successTarget = 0.99

    /// Whether this period's `successRate` met `successTarget`; nil when nothing was judged yet.
    public var met: Bool? { successRate.map { $0 >= DictationStats.successTarget } }

    /// `days`: keep the last N calendar days ending at `today` (yyyy-MM-dd); nil keeps everything.
    public static func compute(lines: [String], days: Int? = nil, today: String) -> DictationStats {
        let from: String? = days.map { d in
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            let t = f.date(from: today) ?? Date()
            return f.string(from: Calendar(identifier: .gregorian).date(byAdding: .day, value: -(d - 1), to: t) ?? t)
        }
        let inRange = { (line: String) -> Bool in
            guard line.prefix(4).allSatisfy(\.isNumber) else { return false }
            return from.map { String(line.prefix(10)) >= $0 } ?? true
        }
        let kept = lines.filter(inRange)
        let entries = kept.compactMap(DictationEntry.parse)
        let started = entries.filter { $0.outcome != .tooShort }
        func pct(_ xs: [Int], _ p: Double) -> Int? {
            guard !xs.isEmpty else { return nil }
            let s = xs.sorted(); return s[min(s.count - 1, Int((Double(s.count) * p).rounded(.up)) - 1)]
        }
        let dictLines = kept.filter { $0.dropFirst(23).hasPrefix(" dictation ") }
        return DictationStats(
            dictations: started.count,
            outcomes: Dictionary(grouping: started, by: \.outcome).mapValues(\.count),
            causes: Dictionary(grouping: started.compactMap(\.cause), by: { $0 }).mapValues(\.count),
            tooShort: entries.count - started.count,
            sentP50: pct(started.compactMap(\.sentMs), 0.5), sentP95: pct(started.compactMap(\.sentMs), 0.95),
            textInP50: pct(started.compactMap(\.textInMs), 0.5), textInP95: pct(started.compactMap(\.textInMs), 0.95),
            tapPaused: kept.filter { $0.contains("event tap was disabled") }.count,
            slowKeys: kept.filter { $0.contains("slow key event") }.count,
            caughtUp: kept.filter { $0.contains(": catching up") }.count,
            tools: Dictionary(grouping: started, by: \.tool).mapValues(\.count),
            firstDay: entries.first?.day, lastDay: entries.last?.day,
            nappedSampled: dictLines.filter { $0.contains("nap: on") || $0.contains("nap: off") }.count,
            napped: dictLines.filter { $0.contains("nap: on") }.count,
            nappedFailed: dictLines.filter { $0.contains("nap: on") && $0.contains("echo missing") }.count,
            selfRelaunches: kept.filter { $0.contains("self-relaunch: ") }.count,
            manualRestarts: kept.filter { $0.dropFirst(23).hasPrefix(" restart: ") }.count,
            aheadSampled: started.filter { $0.listenersAhead != nil }.count,
            listenerAhead: started.filter { $0.listenersAhead?.isEmpty == false }.count,
            listenerAheadFailed: started.filter { $0.listenersAhead?.isEmpty == false && $0.echoSeen == false }.count,
            followed: started.filter(\.follow).count)
    }
}
