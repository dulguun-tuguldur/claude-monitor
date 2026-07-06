// ABOUTME: Models the Claude Code OAuth credential JSON stored in the Keychain and
// ABOUTME: preserves unknown fields so refreshed tokens can be written back safely.
import Foundation

public enum CredentialsError: Error { case malformed }

public struct Credentials: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let rawJSON: Data

    public static func parse(_ data: Data) throws -> Credentials {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String,
              let refresh = oauth["refreshToken"] as? String,
              let expiresMs = oauth["expiresAt"] as? Double
        else { throw CredentialsError.malformed }
        return Credentials(accessToken: access, refreshToken: refresh,
                           expiresAt: Date(timeIntervalSince1970: expiresMs / 1000),
                           rawJSON: data)
    }

    /// Leeway avoids using a token that dies mid-request.
    public func isExpired(now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        now >= expiresAt.addingTimeInterval(-leeway)
    }

    /// New credential JSON with rotated tokens; all fields not owned by us survive.
    public func updatedJSON(accessToken: String, refreshToken: String, expiresAt: Date) throws -> Data {
        guard var obj = try? JSONSerialization.jsonObject(with: rawJSON) as? [String: Any],
              var oauth = obj["claudeAiOauth"] as? [String: Any]
        else { throw CredentialsError.malformed }
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
        obj["claudeAiOauth"] = oauth
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }
}
