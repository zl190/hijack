import XCTest

@testable import HijackCore

// Fixtures: Tests/HijackCoreTests/Fixtures/metrickit/*, hand-written against the documented shape of
// MXMetricPayload / MXDiagnosticPayload (see the file-level comment in Sources/Core/MetricsSummary.swift
// for the Apple doc URLs each key name was checked against).
final class MetricsSummaryTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/metrickit/\(name)")
    }

    func testEmptyFolderIsAnEmptySummary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = MetricsSummary.summarize(folder: dir)
        XCTAssertEqual(s, MetricsSummary())
    }

    func testMissingFolderIsAlsoAnEmptySummary() {
        let s = MetricsSummary.summarize(folder: fixture("does-not-exist"))
        XCTAssertEqual(s, MetricsSummary())
    }

    func testMalformedJSONIsSkippedNotThrown() {
        let s = MetricsSummary.summarize(folder: fixture("malformed-only"))
        XCTAssertEqual(s, MetricsSummary())
    }

    func testCPUTimeSumsPerDayAcrossMetricPayloads() {
        let s = MetricsSummary.summarize(folder: fixture("metrics-only"))
        // metric-day1-a (120.5s) + metric-day1-b (30.0s) on 2026-10-01; metric-day2 (45.25s) on 2026-10-02.
        XCTAssertEqual(s.cpuSecondsByDay["2026-10-01"], 150.5)
        XCTAssertEqual(s.cpuSecondsByDay["2026-10-02"], 45.25)
        XCTAssertEqual(s.totalCPUSeconds, 195.75, accuracy: 0.0001)
    }

    func testPeakMemoryIsTheMaxAcrossMetricPayloads() {
        let s = MetricsSummary.summarize(folder: fixture("metrics-only"))
        // 256 MB, 300 MB, 200 MB -> 300 MB in bytes.
        XCTAssertEqual(s.peakMemoryBytes, 300.0 * 1e6)
    }

    func testHangCountAndLongestHangAcrossDiagnosticPayloads() {
        let s = MetricsSummary.summarize(folder: fixture("diagnostics-only"))
        XCTAssertEqual(s.hangCount, 2)
        XCTAssertEqual(s.longestHangSeconds, 7.75)
    }

    func testCrashCountAndLastCrashDateAcrossDiagnosticPayloads() {
        let s = MetricsSummary.summarize(folder: fixture("diagnostics-only"))
        // diagnostic-hang-and-crash.json ends 2026-10-03, diagnostic-crash-later.json ends 2026-10-04:
        // one crash each, the later file's timeStampEnd wins.
        XCTAssertEqual(s.crashCount, 2)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        XCTAssertEqual(s.lastCrashDate, f.date(from: "2026-10-04T00:00:00.000+0000"))
    }

    func testMixedFolderFoldsEveryFileTogether() {
        let s = MetricsSummary.summarize(folder: fixture("mixed"))
        XCTAssertEqual(s.hangCount, 2)
        XCTAssertEqual(s.crashCount, 2)
        XCTAssertEqual(s.cpuSecondsByDay["2026-10-01"], 120.5)
        XCTAssertEqual(s.cpuSecondsByDay["2026-10-02"], 45.25)
    }

    // MARK: measurement decoding — out of band of a real folder, straight against the helper.

    func testMeasurementReadsAWrappedValueWithAKnownUnit() {
        XCTAssertEqual(MetricsSummary.measurement(["value": 2.0, "unit": "min"], units: MetricsSummary.durationSeconds), 120.0)
    }
    func testMeasurementReadsABareNumberAsAlreadyBaseUnit() {
        XCTAssertEqual(MetricsSummary.measurement(42.0, units: MetricsSummary.durationSeconds), 42.0)
    }
    func testMeasurementKeepsTheRawValueForAnUnknownUnit() {
        XCTAssertEqual(MetricsSummary.measurement(["value": 5.0, "unit": "fortnight"], units: MetricsSummary.durationSeconds), 5.0)
    }
    func testMeasurementIsNilWithoutAValue() {
        XCTAssertNil(MetricsSummary.measurement(["unit": "s"], units: MetricsSummary.durationSeconds))
        XCTAssertNil(MetricsSummary.measurement(nil, units: MetricsSummary.durationSeconds))
    }

    // MARK: branch boundaries — each crosses the edge of a condition in MetricsSummary.fold/summarize.

    func testAFileWithoutTheJSONExtensionIsIgnored() {
        // note.txt holds a well-formed payload, with the wrong extension: 0, not 99 seconds of CPU time.
        let s = MetricsSummary.summarize(folder: fixture("non-json-only"))
        XCTAssertEqual(s, MetricsSummary())
    }

    func testATopLevelJSONArrayIsNotADictionaryAndIsSkipped() {
        let s = MetricsSummary.summarize(folder: fixture("non-dict-only"))
        XCTAssertEqual(s, MetricsSummary())
    }

    func testEmptyHangAndCrashArraysCrossTheNotEmptyBoundary() {
        // hangDiagnostics: [] and crashDiagnostics: [] are present but empty — the opposite edge from
        // diagnostics-only, where both arrays hold at least one entry.
        let s = MetricsSummary.summarize(folder: fixture("empty-arrays-only"))
        XCTAssertEqual(s.hangCount, 0)
        XCTAssertEqual(s.crashCount, 0)
        XCTAssertNil(s.lastCrashDate)
    }

    func testAMetricPayloadWithoutTimeStampBeginContributesNoCPUTime() {
        let s = MetricsSummary.summarize(folder: fixture("missing-begin-only"))
        XCTAssertTrue(s.cpuSecondsByDay.isEmpty)
    }
}
