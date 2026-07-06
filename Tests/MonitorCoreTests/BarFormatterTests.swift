// ABOUTME: Tests the compact-triple bar formatting: rounding, separators,
// ABOUTME: missing windows, and warning/critical level thresholds.
import XCTest
@testable import MonitorCore

final class BarFormatterTests: XCTestCase {
    func snapshot(_ s: Double?, _ w: Double?, _ so: Double?) -> UsageSnapshot {
        UsageSnapshot(
            session: s.map { WindowUsage(utilization: $0, resetsAt: nil) },
            weekAll: w.map { WindowUsage(utilization: $0, resetsAt: nil) },
            weekSonnet: so.map { WindowUsage(utilization: $0, resetsAt: nil) },
            weekOpus: nil, fetchedAt: Date())
    }

    func testPlainTextTriple() {
        XCTAssertEqual(BarFormatter.plainText(for: snapshot(42.2, 18.0, 9.4)), "42·18·9")
    }

    func testMissingWindowsRenderDash() {
        XCTAssertEqual(BarFormatter.plainText(for: snapshot(42.2, 18.0, nil)), "42·18·–")
        XCTAssertEqual(BarFormatter.plainText(for: nil), "–·–·–")
    }

    func testLevels() {
        XCTAssertEqual(BarFormatter.level(for: 69.9), .normal)
        XCTAssertEqual(BarFormatter.level(for: 70.0), .warning)
        XCTAssertEqual(BarFormatter.level(for: 90.0), .critical)
        XCTAssertEqual(BarFormatter.level(for: nil), .missing)
    }

    func testSegmentsCarryLevels() {
        let segs = BarFormatter.segments(for: snapshot(95, 75, 5))
        XCTAssertEqual(segs.map(\.text), ["95", "·", "75", "·", "5"])
        XCTAssertEqual(segs[0].level, .critical)
        XCTAssertEqual(segs[2].level, .warning)
        XCTAssertEqual(segs[4].level, .normal)
    }
}
