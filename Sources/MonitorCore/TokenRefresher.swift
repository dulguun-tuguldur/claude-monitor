// ABOUTME: Refreshes an expired Claude Code OAuth token pair (the same flow the
// ABOUTME: CLI uses) so the monitor can watch accounts that haven't run recently.
import Foundation

public enum RefreshError: Error, Equatable { case rejected, http(Int), malformed }

public struct TokenRefresher: Sendable {
    /// Claude Code's public OAuth client id (verify in Task 0 spike notes).
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let defaultURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    public struct Refreshed: Equatable, Sendable {
        public let accessToken: String
        public let refreshToken: String
        public let expiresAt: Date
    }

    let session: URLSession
    let tokenURL: URL

    public init(session: URLSession = .shared) {
        self.session = session
        let env = ProcessInfo.processInfo.environment["CM_TOKEN_URL"]
        self.tokenURL = env.flatMap(URL.init(string:)) ?? Self.defaultURL
    }

    public func refresh(refreshToken: String) async throws -> Refreshed {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ])
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 400 || code == 401 { throw RefreshError.rejected }
        guard (200..<300).contains(code) else { throw RefreshError.http(code) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String,
              let expiresIn = obj["expires_in"] as? Double
        else { throw RefreshError.malformed }
        return Refreshed(accessToken: access, refreshToken: refresh,
                         expiresAt: Date().addingTimeInterval(expiresIn))
    }
}
