// ABOUTME: Tests lenient decoding of the OAuth usage endpoint response:
// ABOUTME: full plans, plans without per-model windows, Fable limits rows, and garbage input.
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
        XCTAssertNil(s.weekFable)
        XCTAssertEqual(s.weekAll?.utilization, 18.0)
    }

    func testParseFableFromLimitsRows() throws {
        let s = try UsageSnapshot.parse(fixture("usage-full"))
        XCTAssertEqual(s.weekFable?.utilization, 27.6)
        XCTAssertEqual(s.weekFable?.resetsAt, UsageSnapshot.parseISO("2026-07-08T00:00:00Z"))
    }

    /// Captured live response: integer `percent`, microsecond `resets_at` with a
    /// `+00:00` offset, and dozens of null top-level windows.
    func testParseLiveResponseWithFableRow() throws {
        let s = try UsageSnapshot.parse(fixture("usage-live-fable"))
        XCTAssertEqual(s.session?.utilization, 8.0)
        XCTAssertEqual(s.weekAll?.utilization, 11.0)
        XCTAssertNil(s.weekSonnet)
        XCTAssertEqual(s.weekFable?.utilization, 5.0)
        XCTAssertEqual(s.weekFable?.resetsAt?.timeIntervalSince1970 ?? 0,
                       UsageSnapshot.parseISO("2026-11-29T07:00:00Z")!.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(BarFormatter.plainText(for: s), "8·11·5")
    }

    func testFableMatchIgnoresCaseAndOtherKinds() throws {
        let json = #"""
        {"limits":[
          {"kind":"weekly_all","percent":50.0,"resets_at":null,"scope":{"model":{"display_name":"Fable"}}},
          {"kind":"weekly_scoped","percent":7.0,"resets_at":null,"scope":{"model":{"display_name":"fable"}}}
        ]}
        """#
        let s = try UsageSnapshot.parse(Data(json.utf8))
        XCTAssertEqual(s.weekFable?.utilization, 7.0)
        XCTAssertNil(s.weekFable?.resetsAt)
    }

    func testFableEpochSecondsResetsAt() throws {
        let json = #"{"limits":[{"kind":"weekly_scoped","percent":7.0,"resets_at":1783468800,"scope":{"model":{"display_name":"Fable"}}}]}"#
        let s = try UsageSnapshot.parse(Data(json.utf8))
        XCTAssertEqual(s.weekFable?.resetsAt, Date(timeIntervalSince1970: 1783468800))
    }

    func testMalformedLimitsRowsAreIgnored() throws {
        let json = #"{"seven_day":{"utilization":18.0},"limits":[null,"x",{"kind":"weekly_scoped"},{"kind":"weekly_scoped","percent":"9","scope":{"model":{"display_name":"Fable"}}}]}"#
        let s = try UsageSnapshot.parse(Data(json.utf8))
        XCTAssertNil(s.weekFable)
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
