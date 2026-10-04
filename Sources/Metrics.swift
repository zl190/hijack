import Foundation
import MetricKit

// MARK: MetricKit subscriber — macOS delivers an MXMetricPayload about once a day, and an
// MXDiagnosticPayload when the app hangs or crashes (https://developer.apple.com/documentation/metrickit).
// This file only writes the payloads to disk; Sources/Core/MetricsSummary.swift reads them back.

/// `~/Library/Logs/Hijack-metrics`, next to Hijack.log (Sources/Shared.swift).
let metricsFolderURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(appName)-metrics")
let metricsKeepCount = 30
private let metricsQueue = DispatchQueue(label: "com.zl190.hijack.metrics", qos: .utility)
private let metricsFileStamp: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HHmmss"; return f
}()

/// Subscribes to MetricKit; one instance, added to `MXMetricManager.shared` once in
/// `applicationDidFinishLaunching` (Sources/Menu.swift). Every delivery writes each payload's
/// `jsonRepresentation()` to its own file, off the main thread: the main thread serves the key tap, and
/// must never block on file I/O (the same rule `log()` follows in Sources/Shared.swift).
final class MetricsRecorder: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) { write(kind: "metric", jsons: payloads.map { $0.jsonRepresentation() }) }
    func didReceive(_ payloads: [MXDiagnosticPayload]) { write(kind: "diagnostic", jsons: payloads.map { $0.jsonRepresentation() }) }

    private func write(kind: String, jsons: [Data]) {
        guard !jsons.isEmpty else { return }
        metricsQueue.async {
            try? FileManager.default.createDirectory(at: metricsFolderURL, withIntermediateDirectories: true)
            let stamp = metricsFileStamp.string(from: Date())
            for (i, json) in jsons.enumerated() {
                let name = "\(stamp)-\(kind)-\(i).json"
                try? json.write(to: metricsFolderURL.appendingPathComponent(name), options: .atomic)
            }
            MetricsRecorder.trim()
            log("metrics: \(jsons.count) payloads written")
        }
    }

    /// Keeps the newest `metricsKeepCount` files (file names sort chronologically: the stamp is the
    /// ISO-ish date prefix), deletes the rest.
    private static func trim() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: metricsFolderURL.path) else { return }
        let sorted = names.sorted()
        guard sorted.count > metricsKeepCount else { return }
        for name in sorted.prefix(sorted.count - metricsKeepCount) {
            try? fm.removeItem(at: metricsFolderURL.appendingPathComponent(name))
        }
    }
}
