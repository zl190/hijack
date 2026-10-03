import XCTest
@testable import HijackCore

// review-5 #14: Config.swift (outside this package's test target) writes config.json by hand and loads
// numbers with no range check. The risky parts are pulled into Core/ConfigValues.swift, pure, so they
// are covered here.
final class ConfigValuesTests: XCTestCase {
    // `hijack set source 'a"b'` used to write invalid JSON and wedge every later save().
    func testJSONLiteral_AStringWithAQuoteRoundTrips() {
        let raw = "a\"b"
        let literal = jsonLiteral(raw)
        let parsed = try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: [.fragmentsAllowed]) as? String
        XCTAssertEqual(parsed, raw, "encoded as \(literal)")
    }
    func testJSONLiteral_BackslashesAndControlCharactersRoundTrip() {
        let raw = "back\\slash\nand\ttabs"
        let literal = jsonLiteral(raw)
        let parsed = try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: [.fragmentsAllowed]) as? String
        XCTAssertEqual(parsed, raw, "encoded as \(literal)")
    }
    // Out-of-range: an empty string (no quote, no backslash) still round-trips, same code path either way.
    func testJSONLiteral_PlainStringRoundTrips() {
        let literal = jsonLiteral("plain")
        XCTAssertEqual(literal, "\"plain\"")
    }
    func testJSONLiteral_BoolAndDoubleAreNotQuoted() {
        XCTAssertEqual(jsonLiteral(true), "true")
        XCTAssertEqual(jsonLiteral(false), "false")
        XCTAssertEqual(jsonLiteral(0.2), "0.2")
    }

    // A hand edit can set an absurd wait (a 10-minute restoreTimeout): loading must clamp it, and say so.
    func testClampedTiming_OutOfRangeIsClampedAndLogged() {
        let (value, logLine) = clampedTiming(600, to: restoreTimeoutRange, name: "restoreTimeout")
        XCTAssertEqual(value, restoreTimeoutRange.upperBound)
        XCTAssertEqual(logLine, "config: restoreTimeout 600.0 out of range 1.0...15.0, clamped to 15.0")
    }
    func testClampedTiming_BelowRangeClampsToTheLowerBound() {
        let (value, logLine) = clampedTiming(-1, to: holdDelayRange, name: "holdDelay")
        XCTAssertEqual(value, holdDelayRange.lowerBound)
        XCTAssertNotNil(logLine)
    }
    // Out-of-range (for the clamp itself): a value already inside the range is returned unchanged, no log.
    func testClampedTiming_InRangeIsUnchangedAndNotLogged() {
        let (value, logLine) = clampedTiming(0.3, to: holdDelayRange, name: "holdDelay")
        XCTAssertEqual(value, 0.3)
        XCTAssertNil(logLine)
    }
}
