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

    /// Locale fixed to en_US_POSIX so the bar always reads "3:45 PM" regardless of
    /// the system locale, since the AM/PM format was requested explicitly.
    private static let sessionResetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f
    }()

    /// Session (5-hour window) reset time in AM/PM format, e.g. "3:45 PM". Nil when
    /// the snapshot, its session window, or the window's reset time is absent.
    public static func sessionResetText(for snapshot: UsageSnapshot?, timeZone: TimeZone = .current) -> String? {
        guard let resetsAt = snapshot?.session?.resetsAt else { return nil }
        sessionResetFormatter.timeZone = timeZone
        return sessionResetFormatter.string(from: resetsAt)
    }
}
