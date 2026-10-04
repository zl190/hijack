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
// What those pages do not show: a full `jsonRepresentation()` sample. A `Measurement` property
// (cumulativeCPUTime, peakMemoryUsage, hangDuration) is read here as either a nested
// `{"value": <number>, "unit": "<symbol>"}` object or a bare number, so a change in the exact encoding
// degrades to "no value" instead of a crash. Known unit symbols convert to seconds / bytes below; an
// unrecognized symbol is treated as already being in the base unit.
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

    public init() {}
    public init(
        hangCount: Int = 0, longestHangSeconds: Double? = nil, crashCount: Int = 0, lastCrashDate: Date? = nil,
        cpuSecondsByDay: [String: Double] = [:], peakMemoryBytes: Double? = nil
    ) {
        self.hangCount = hangCount; self.longestHangSeconds = longestHangSeconds
        self.crashCount = crashCount; self.lastCrashDate = lastCrashDate
        self.cpuSecondsByDay = cpuSecondsByDay; self.peakMemoryBytes = peakMemoryBytes
    }

    /// Every `cumulativeCPUTime`, summed, across every day: the total CPU time in the folder.
    public var totalCPUSeconds: Double { cpuSecondsByDay.values.reduce(0, +) }

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
                guard let seconds = measurement(h["hangDuration"], units: durationSeconds) else { continue }
                out.longestHangSeconds = max(out.longestHangSeconds ?? 0, seconds)
            }
        }
        if let crashes = obj["crashDiagnostics"] as? [[String: Any]], !crashes.isEmpty {
            out.crashCount += crashes.count
            if let when = end ?? begin { out.lastCrashDate = max(out.lastCrashDate ?? when, when) }
        }
        if let cpu = obj["cpuMetrics"] as? [String: Any], let begin,
            let seconds = measurement(cpu["cumulativeCPUTime"], units: durationSeconds)
        {
            out.cpuSecondsByDay[day(begin), default: 0] += seconds
        }
        if let mem = obj["memoryMetrics"] as? [String: Any], let bytes = measurement(mem["peakMemoryUsage"], units: infoStorageBytes) {
            out.peakMemoryBytes = max(out.peakMemoryBytes ?? 0, bytes)
        }
    }

    // MARK: decoding helpers

    /// `{"value": <number>, "unit": "<symbol>"}` -> value * units[symbol] (default 1 for an unknown
    /// symbol, or when the symbol is missing). A bare number is read as already being in the base unit.
    static func measurement(_ any: Any?, units: [String: Double]) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        guard let d = any as? [String: Any], let v = d["value"] as? NSNumber else { return nil }
        let unit = d["unit"] as? String
        return v.doubleValue * (unit.flatMap { units[$0] } ?? 1)
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
