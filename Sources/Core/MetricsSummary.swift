import Foundation

// MARK: MetricKit summary — a pure parser over the JSON files Sources/Metrics.swift writes from
// MXMetricPayload.jsonRepresentation() and MXDiagnosticPayload.jsonRepresentation()
// (https://developer.apple.com/documentation/metrickit).
//
// Every key name read below comes straight off Apple's reference pages (fetched 2026-10-04), not a guess:
//   developer.apple.com/documentation/metrickit/mxmetricpayload
//     timeStampBegin, timeStampEnd, cpuMetrics, memoryMetrics, applicationTimeMetrics, metaData
//   developer.apple.com/documentation/metrickit/mxcpumetric        cumulativeCPUTime: Measurement<UnitDuration>
//   developer.apple.com/documentation/metrickit/mxmemorymetric     peakMemoryUsage: Measurement<UnitInformationStorage>
//   developer.apple.com/documentation/metrickit/mxdiagnosticpayload  timeStampBegin, timeStampEnd, hangDiagnostics, crashDiagnostics
//   developer.apple.com/documentation/metrickit/mxhangdiagnostic   hangDuration: Measurement<UnitDuration>
//   developer.apple.com/documentation/metrickit/mxcrashdiagnostic  terminationReason, exceptionType, exceptionCode, signal, exceptionReason
//   developer.apple.com/documentation/metrickit/mxdiagnostic       metaData — the field both diagnostic kinds inherit (the key
//     is "metaData", not "diagnosticMetaData"; neither page below lists a "diagnosticMetaData" property)
//
// What those pages do not show: a full `jsonRepresentation()` sample. Review 6 (S1) raised two concrete
// alternatives, settled empirically where possible and defended against otherwise:
//   (a) A 20-line probe (not in this repo) called `MXMetricManager.shared.pastPayloads` /
//       `.pastDiagnosticPayloads` on this Mac to print a real payload. Both were empty (count 0) — there
//       is still no real payload to check the parser against, so (b) and (c) below are defensive, not
//       confirmed by a device sample.
//   (b) A `Measurement` property (cumulativeCPUTime, peakMemoryUsage, hangDuration) is read as a bare
//       number, a `{"value": <number>, "unit": "<symbol>"}` object, OR a string with a unit suffix
//       ("120.5 sec", "200,000 kB" — grouping commas stripped): public jsonRepresentation() samples are
//       said to write it that third way. An unrecognized unit symbol is nil, not guessed as 1x the base
//       unit (an unrecognized "KB" must not silently read as bytes, 1000x too small).
//       `hangDuration` is read directly on the hang object (as documented), and also, as a fallback, from
//       a nested "diagnosticMetaData" or "metaData" object — the review cites `diagnosticMetaData` as a
//       key the framework's own strings carry; Apple's MXDiagnostic reference page documents the shared
//       metadata property as "metaData", not "diagnosticMetaData" (neither page lists the latter), but
//       both locations are read so the parser does not depend on which name wins.
//   A date (timeStampBegin/End) is read as ISO-8601 or "yyyy-MM-dd HH:mm:ss Z"; both are tested.
// (c) When a section's key exists but its value does not parse under any of the above, that is recorded
//     (fooUnparsed = true, parseWarnings += 1) instead of being silently read as absent/zero: a 0 that
//     came from a key Hijack could not read is not a fact worth printing as one.
// Neither MXHangDiagnostic nor MXCrashDiagnostic carries its own timestamp (absent from both reference
// pages above), so "when" a hang or a crash happened is read as the containing payload's timeStampEnd.

/// One summary over a folder of MetricKit payload files.
public struct MetricsSummary: Equatable {
    public var hangCount = 0
    public var longestHangSeconds: Double?
    public var crashCount = 0
    public var lastCrashDate: Date?
    /// yyyy-MM-dd (local time, matching the rest of the app's day keys) -> seconds, summed over every
    /// metric payload whose `timeStampBegin` falls on that day.
    public var cpuSecondsByDay: [String: Double] = [:]
    public var peakMemoryBytes: Double?
    /// True when a hangDuration/cumulativeCPUTime/peakMemoryUsage key was present in at least one file,
    /// but its value never parsed (S1(c)): the corresponding field above may still be nil, or it may hold
    /// a value from a different file — this only says at least one instance was unreadable.
    public var longestHangUnparsed = false
    public var cpuTimeUnparsed = false
    public var peakMemoryUnparsed = false
    /// Count of every present-but-unparsed value above, summed across every file: the number for `--json`.
    public var parseWarnings = 0

    public init() {}
    public init(
        hangCount: Int = 0, longestHangSeconds: Double? = nil, crashCount: Int = 0, lastCrashDate: Date? = nil,
        cpuSecondsByDay: [String: Double] = [:], peakMemoryBytes: Double? = nil,
        longestHangUnparsed: Bool = false, cpuTimeUnparsed: Bool = false, peakMemoryUnparsed: Bool = false, parseWarnings: Int = 0
    ) {
        self.hangCount = hangCount; self.longestHangSeconds = longestHangSeconds
        self.crashCount = crashCount; self.lastCrashDate = lastCrashDate
        self.cpuSecondsByDay = cpuSecondsByDay; self.peakMemoryBytes = peakMemoryBytes
        self.longestHangUnparsed = longestHangUnparsed; self.cpuTimeUnparsed = cpuTimeUnparsed
        self.peakMemoryUnparsed = peakMemoryUnparsed; self.parseWarnings = parseWarnings
    }

    /// Every `cumulativeCPUTime`, summed, across every day: the total CPU time in the folder.
    public var totalCPUSeconds: Double { cpuSecondsByDay.values.reduce(0, +) }

    /// `doctor`'s "a crash report newer than the last start" rule (review 6, S2), as a pure comparison:
    /// `startedAt` must be the app's actual start time, not a field rewritten on every later state write
    /// (the old rule compared against `state.json`'s `updated`, which moves on every dictation and menu
    /// open — a crash before the latest `updated` but after the real start went unreported). Equal
    /// timestamps are not "newer"; no crash is never newer than anything.
    public static func crashIsNewerThanStart(lastCrash: Date?, startedAt: Date) -> Bool {
        guard let lastCrash else { return false }
        return lastCrash > startedAt
    }

    /// Reads every `*.json` file directly inside `folder` and folds it into one summary. A file that
    /// isn't valid JSON, or isn't a dictionary at its top level, is skipped — one bad file never drops
    /// the rest. Missing folder: an empty summary, not an error (stats/doctor show "no payloads yet").
    public static func summarize(folder: URL, fileManager: FileManager = .default) -> MetricsSummary {
        var out = MetricsSummary()
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path))?.sorted() ?? []
        for name in names where name.hasSuffix(".json") {
            guard let data = fileManager.contents(atPath: folder.appendingPathComponent(name).path),
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            fold(obj, into: &out)
        }
        return out
    }

    private static func fold(_ obj: [String: Any], into out: inout MetricsSummary) {
        let begin = date(obj["timeStampBegin"]), end = date(obj["timeStampEnd"])
        if let hangs = obj["hangDiagnostics"] as? [[String: Any]] {
            out.hangCount += hangs.count
            for h in hangs {
                let raw = hangDurationRaw(h)
                if let seconds = measurement(raw, units: durationSeconds) {
                    out.longestHangSeconds = max(out.longestHangSeconds ?? 0, seconds)
                } else if raw != nil {
                    out.longestHangUnparsed = true; out.parseWarnings += 1
                }
            }
        }
        if let crashes = obj["crashDiagnostics"] as? [[String: Any]], !crashes.isEmpty {
            out.crashCount += crashes.count
            if let when = end ?? begin { out.lastCrashDate = max(out.lastCrashDate ?? when, when) }
        }
        if let cpu = obj["cpuMetrics"] as? [String: Any] {
            let raw = cpu["cumulativeCPUTime"]
            let seconds = measurement(raw, units: durationSeconds)
            if let begin, let seconds {
                out.cpuSecondsByDay[day(begin), default: 0] += seconds
            } else if raw != nil, seconds == nil {
                // Only a true parse failure counts as a warning: a payload missing timeStampBegin, with
                // an otherwise-readable cumulativeCPUTime, just has nowhere to bucket it (see
                // testAMetricPayloadWithoutTimeStampBeginContributesNoCPUTime) — that is not unparsed.
                out.cpuTimeUnparsed = true; out.parseWarnings += 1
            }
        }
        if let mem = obj["memoryMetrics"] as? [String: Any] {
            let raw = mem["peakMemoryUsage"]
            if let bytes = measurement(raw, units: infoStorageBytes) {
                out.peakMemoryBytes = max(out.peakMemoryBytes ?? 0, bytes)
            } else if raw != nil {
                out.peakMemoryUnparsed = true; out.parseWarnings += 1
            }
        }
    }

    /// `hangDuration` as MXHangDiagnostic documents it (directly on the hang object), falling back to a
    /// nested "diagnosticMetaData" or "metaData" object (S1(b) — see the file header).
    private static func hangDurationRaw(_ h: [String: Any]) -> Any? {
        h["hangDuration"] ?? (h["diagnosticMetaData"] as? [String: Any])?["hangDuration"]
            ?? (h["metaData"] as? [String: Any])?["hangDuration"]
    }

    // MARK: decoding helpers

    /// A Measurement, in any of three shapes: a bare number (already the base unit), a
    /// `{"value": <number>, "unit": "<symbol>"}` object, or a unit-suffixed string ("120.5 sec",
    /// "200,000 kB" — see `measurementString`). An unrecognized unit symbol is nil, never guessed as 1x
    /// the base unit (S1(b)): a missing "unit" key is read as the base unit, since there is no symbol to
    /// misread, but a present, unrecognized one is refused rather than silently scaled wrong.
    static func measurement(_ any: Any?, units: [String: Double]) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return measurementString(s, units: units) }
        guard let d = any as? [String: Any], let v = d["value"] as? NSNumber else { return nil }
        guard let unit = d["unit"] as? String else { return v.doubleValue }
        guard let factor = units[unit] else { return nil }
        return v.doubleValue * factor
    }

    /// "<number> <unit>", comma grouping stripped from the number ("200,000 kB" -> 200000 * kB's factor).
    /// nil for anything else, including a recognized number with an unrecognized unit.
    private static func measurementString(_ s: String, units: [String: Double]) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0].replacingOccurrences(of: ",", with: "")),
            let factor = units[String(parts[1])]
        else { return nil }
        return value * factor
    }

    static let durationSeconds: [String: Double] = ["s": 1, "sec": 1, "ms": 0.001, "min": 60, "hr": 3600, "µs": 1e-6, "ns": 1e-9]
    static let infoStorageBytes: [String: Double] = [
        "byte": 1, "bit": 0.125, "kB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12,
        "KiB": 1024, "MiB": 1024 * 1024, "GiB": 1024 * 1024 * 1024,
    ]

    /// `timeStampBegin`/`timeStampEnd`, as either an ISO-8601 string or seconds-since-epoch.
    static func date(_ any: Any?) -> Date? {
        if let n = any as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        guard let s = any as? String else { return nil }
        for f in dateFormatters { if let d = f.date(from: s) { return d } }
        return nil
    }
    private static let dateFormatters: [DateFormatter] = {
        [
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss",
        ].map { pattern in
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = pattern; return f
        }
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static func day(_ d: Date) -> String { dayFormatter.string(from: d) }
}
