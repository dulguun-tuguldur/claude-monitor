// ABOUTME: Turns a usage snapshot into the menu bar's compact "42·18·9" segments
// ABOUTME: with severity levels the UI maps to colors; pure logic, fully testable.
import Foundation

public enum UsageLevel: Equatable, Sendable { case normal, warning, critical, missing }

public struct BarSegment: Equatable, Sendable {
    public let text: String
    public let level: UsageLevel
    public init(text: String, level: UsageLevel) {
        self.text = text
        self.level = level
    }
}

public enum BarFormatter {
    public static func level(for utilization: Double?) -> UsageLevel {
        guard let u = utilization else { return .missing }
        if u >= 90 { return .critical }
        if u >= 70 { return .warning }
        return .normal
    }

    /// Fixed order: session · week(all) · week(sonnet). Absent window → "–".
    public static func segments(for snapshot: UsageSnapshot?) -> [BarSegment] {
        let windows = [snapshot?.session, snapshot?.weekAll, snapshot?.weekSonnet]
        var out: [BarSegment] = []
        for (i, w) in windows.enumerated() {
            if i > 0 { out.append(BarSegment(text: "·", level: .normal)) }
            if let u = w?.utilization {
                out.append(BarSegment(text: String(Int(u.rounded())), level: level(for: u)))
            } else {
                out.append(BarSegment(text: "–", level: .missing))
            }
        }
        return out
    }

    /// Plain-text form used by --print-once and tests, e.g. "42·18·9".
    public static func plainText(for snapshot: UsageSnapshot?) -> String {
        segments(for: snapshot).map(\.text).joined()
    }
}
