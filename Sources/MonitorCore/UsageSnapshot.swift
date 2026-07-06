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

    public let session: WindowUsage?
    public let weekAll: WindowUsage?
    public let weekSonnet: WindowUsage?
    public let weekOpus: WindowUsage?
    public let fetchedAt: Date

    public init(session: WindowUsage?, weekAll: WindowUsage?, weekSonnet: WindowUsage?,
                weekOpus: WindowUsage?, fetchedAt: Date) {
        self.session = session
        self.weekAll = weekAll
        self.weekSonnet = weekSonnet
        self.weekOpus = weekOpus
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
                             fetchedAt: now)
    }

    static func parseISO(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s)
    }
}
