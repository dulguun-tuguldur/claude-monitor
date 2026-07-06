// ABOUTME: Fetches usage utilization from Anthropic's OAuth usage endpoint using
// ABOUTME: an account's access token; base URL overridable for tests/E2E.
import Foundation

public struct UsageClient: Sendable {
    public static let defaultURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    let session: URLSession
    let baseURL: URL

    public init(session: URLSession = .shared) {
        self.session = session
        let env = ProcessInfo.processInfo.environment["CM_USAGE_URL"]
        self.baseURL = env.flatMap(URL.init(string:)) ?? Self.defaultURL
    }

    public func fetchUsage(accessToken: String) async throws -> UsageSnapshot {
        var req = URLRequest(url: baseURL)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw UsageError.unauthorized }
        guard (200..<300).contains(code) else { throw UsageError.http(code) }
        return try UsageSnapshot.parse(data)
    }
}
