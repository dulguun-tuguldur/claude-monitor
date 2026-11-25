// ABOUTME: Models the response of Anthropic's OAuth usage endpoint (the data behind
// ABOUTME: Claude Code's /usage screen) with lenient decoding for plan differences.
import Foundation

public enum UsageError: Error, Equatable { case malformed, unauthorized, http(Int) }

public struct WindowUsage: Equatable, Sendable {
    public let utilization: Double // 0–100
    public let resetsAt: Date?
    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    // Response keys — verified/adjusted from Task 0 spike capture.
    static let sessionKey = "five_hour"
    static let weekAllKey = "seven_day"
    static let weekSonnetKey = "seven_day_sonnet"
    static let weekOpusKey = "seven_day_opus"
    // Per-model weekly windows arrive as rows of the `limits` array rather than as
    // top-level keys; a Fable row has kind "weekly_scoped" and that model's label.
    static let limitsKey = "limits"
    static let weeklyScopedKind = "weekly_scoped"
    static let fableModelName = "Fable"

    public let session: WindowUsage?
    public let weekAll: WindowUsage?
    public let weekSonnet: WindowUsage?
    public let weekOpus: WindowUsage?
    public let weekFable: WindowUsage?
    public let fetchedAt: Date

    public init(session: WindowUsage?, weekAll: WindowUsage?, weekSonnet: WindowUsage?,
                weekOpus: WindowUsage?, weekFable: WindowUsage? = nil, fetchedAt: Date) {
        self.session = session
        self.weekAll = weekAll
        self.weekSonnet = weekSonnet
        self.weekOpus = weekOpus
        self.weekFable = weekFable
        self.fetchedAt = fetchedAt
    }

    public static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageError.malformed }
        func window(_ key: String) -> WindowUsage? {
            guard let w = obj[key] as? [String: Any],
                  let u = w["utilization"] as? Double else { return nil }
            return WindowUsage(utilization: u, resetsAt: (w["resets_at"] as? String).flatMap(parseISO))
        }
        return UsageSnapshot(session: window(sessionKey), weekAll: window(weekAllKey),
                             weekSonnet: window(weekSonnetKey), weekOpus: window(weekOpusKey),
                             weekFable: modelWindow(fableModelName, in: obj[limitsKey]),
                             fetchedAt: now)
    }

    /// Finds the weekly row scoped to `model` (case-insensitive) in the `limits`
    /// array. Rows that don't have the expected shape are skipped, not fatal.
    static func modelWindow(_ model: String, in limits: Any?) -> WindowUsage? {
        guard let rows = limits as? [Any] else { return nil }
        for case let row as [String: Any] in rows {
            guard row["kind"] as? String == weeklyScopedKind,
                  let scope = row["scope"] as? [String: Any],
                  let scopedModel = scope["model"] as? [String: Any],
                  let name = scopedModel["display_name"] as? String,
                  name.caseInsensitiveCompare(model) == .orderedSame,
                  let percent = row["percent"] as? Double else { continue }
            return WindowUsage(utilization: percent, resetsAt: parseResetsAt(row["resets_at"]))
        }
        return nil
    }

    /// `resets_at` is normally an ISO 8601 string; epoch seconds are accepted too.
    static func parseResetsAt(_ value: Any?) -> Date? {
        if let s = value as? String { return parseISO(s) }
        if let n = value as? Double { return Date(timeIntervalSince1970: n) }
        return nil
    }

    static func parseISO(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s)
    }
}
