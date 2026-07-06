// ABOUTME: Tests lenient decoding of the OAuth usage endpoint response:
// ABOUTME: full plans, plans without per-model windows, and garbage input.
import XCTest
@testable import MonitorCore

final class UsageSnapshotTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!)
    }

    func testParseFull() throws {
        let s = try UsageSnapshot.parse(fixture("usage-full"))
        XCTAssertEqual(s.session?.utilization, 42.2)
        XCTAssertEqual(s.weekAll?.utilization, 18.0)
        XCTAssertEqual(s.weekSonnet?.utilization, 9.4)
        XCTAssertEqual(s.weekOpus?.utilization, 5.0)
        XCTAssertNotNil(s.session?.resetsAt)
    }

    func testParseWithoutSonnet() throws {
        let s = try UsageSnapshot.parse(fixture("usage-no-sonnet"))
        XCTAssertNil(s.weekSonnet)
        XCTAssertEqual(s.weekAll?.utilization, 18.0)
    }

    func testFractionalSecondsDate() throws {
        let json = #"{"five_hour":{"utilization":1.0,"resets_at":"2026-07-05T16:00:00.123Z"}}"#
        let s = try UsageSnapshot.parse(Data(json.utf8))
        XCTAssertNotNil(s.session?.resetsAt)
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try UsageSnapshot.parse(Data("[]".utf8)))
    }
}
