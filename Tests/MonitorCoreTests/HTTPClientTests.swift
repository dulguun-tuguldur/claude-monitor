// ABOUTME: Tests UsageClient request formation and status handling, and
// ABOUTME: TokenRefresher's refresh request/response round-trip, via mock HTTP.
import XCTest
@testable import MonitorCore

final class HTTPClientTests: XCTestCase {
    func testUsageClientSendsAuthAndBetaHeaders() async throws {
        var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return try MockURLProtocol.respond(status: 200,
                json: #"{"five_hour":{"utilization":42.2,"resets_at":"2026-07-05T16:00:00Z"}}"#)(req)
        }
        let client = UsageClient(session: MockURLProtocol.session())
        let snap = try await client.fetchUsage(accessToken: "tok-123")
        XCTAssertEqual(snap.session?.utilization, 42.2)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }

    func testUsageClient401ThrowsUnauthorized() async {
        MockURLProtocol.handler = MockURLProtocol.respond(status: 401, json: "{}")
        let client = UsageClient(session: MockURLProtocol.session())
        do { _ = try await client.fetchUsage(accessToken: "t"); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? UsageError, .unauthorized) }
    }

    func testRefresherParsesTokenResponse() async throws {
        var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return try MockURLProtocol.respond(status: 200,
                json: #"{"access_token":"A2","refresh_token":"R2","expires_in":28800}"#)(req)
        }
        let refresher = TokenRefresher(session: MockURLProtocol.session())
        let r = try await refresher.refresh(refreshToken: "R1")
        XCTAssertEqual(r.accessToken, "A2")
        XCTAssertEqual(r.refreshToken, "R2")
        XCTAssertGreaterThan(r.expiresAt, Date().addingTimeInterval(28000))
        let body = try JSONSerialization.jsonObject(with: captured!.bodyData()) as! [String: Any]
        XCTAssertEqual(body["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(body["refresh_token"] as? String, "R1")
        XCTAssertEqual(body["client_id"] as? String, TokenRefresher.clientID)
    }

    func testRefresher400ThrowsRefreshRejected() async {
        MockURLProtocol.handler = MockURLProtocol.respond(status: 400, json: "{}")
        let refresher = TokenRefresher(session: MockURLProtocol.session())
        do { _ = try await refresher.refresh(refreshToken: "R1"); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? RefreshError, .rejected) }
    }
}

extension URLRequest {
    /// httpBody is consumed into a stream by URLProtocol; read it back for asserts.
    func bodyData() -> Data {
        if let b = httpBody { return b }
        guard let stream = httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}
