// ABOUTME: Tests the polling engine: happy path, expired-token refresh with
// ABOUTME: write-back, 401 retry, network degradation to stale, missing creds.
import XCTest
@testable import MonitorCore

@MainActor
final class PollerTests: XCTestCase {
    let acct = Account(configDir: URL(fileURLWithPath: "/tmp/.claude-p1"))
    var store: FakeCredentialStore!

    override func setUp() {
        store = FakeCredentialStore()
        MockURLProtocol.handler = nil
    }

    func fixtureCreds(_ name: String) throws -> Credentials {
        try Credentials.parse(Data(contentsOf:
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!))
    }

    func makePoller() -> Poller {
        let session = MockURLProtocol.session()
        return Poller(store: store,
                      usage: UsageClient(session: session),
                      refresher: TokenRefresher(session: session),
                      discover: { [self.acct] })
    }

    func testHappyPath() async throws {
        store.creds[acct.id] = try fixtureCreds("credentials-valid")
        MockURLProtocol.handler = MockURLProtocol.respond(status: 200,
            json: #"{"five_hour":{"utilization":42.0},"seven_day":{"utilization":18.0},"seven_day_sonnet":{"utilization":9.0}}"#)
        let poller = makePoller()
        await poller.pollAll()
        guard case .ok(let snap) = poller.states().first?.status else { return XCTFail() }
        XCTAssertEqual(BarFormatter.plainText(for: snap), "42·18·9")
        XCTAssertTrue(store.writes.isEmpty) // fresh token → no keychain writes
    }

    func testExpiredTokenRefreshesAndWritesBack() async throws {
        store.creds[acct.id] = try fixtureCreds("credentials-expired")
        MockURLProtocol.handler = { req in
            if req.url!.path.contains("oauth/token") {
                return try MockURLProtocol.respond(status: 200,
                    json: #"{"access_token":"A2","refresh_token":"R2","expires_in":28800}"#)(req)
            }
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer A2")
            return try MockURLProtocol.respond(status: 200,
                json: #"{"five_hour":{"utilization":1.0}}"#)(req)
        }
        let poller = makePoller()
        await poller.pollAll()
        guard case .ok = poller.states().first?.status else { return XCTFail() }
        XCTAssertEqual(store.writes.count, 1)
        XCTAssertEqual(store.creds[acct.id]?.accessToken, "A2") // rotation persisted
    }

    func testRefreshRejectedMarksReloginNeeded() async throws {
        store.creds[acct.id] = try fixtureCreds("credentials-expired")
        MockURLProtocol.handler = MockURLProtocol.respond(status: 400, json: "{}")
        let poller = makePoller()
        await poller.pollAll()
        XCTAssertEqual(poller.states().first?.status, .reloginNeeded)
    }

    func testNetworkErrorDegradesToStale() async throws {
        store.creds[acct.id] = try fixtureCreds("credentials-valid")
        MockURLProtocol.handler = MockURLProtocol.respond(status: 200,
            json: #"{"five_hour":{"utilization":42.0}}"#)
        let poller = makePoller()
        await poller.pollAll()
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await poller.pollAll()
        guard case .stale(let snap) = poller.states().first?.status else { return XCTFail() }
        XCTAssertEqual(snap.session?.utilization, 42.0) // old data retained
    }

    func testRetryAfterRefreshFailsTransientlyDoesNotSetReloginNeeded() async throws {
        store.creds[acct.id] = try fixtureCreds("credentials-valid")
        var usageCallCount = 0
        MockURLProtocol.handler = { req in
            if req.url!.path.contains("oauth/token") {
                return try MockURLProtocol.respond(status: 200,
                    json: #"{"access_token":"A2","refresh_token":"R2","expires_in":28800}"#)(req)
            }
            usageCallCount += 1
            if usageCallCount == 1 {
                return try MockURLProtocol.respond(status: 401, json: "{}")(req)
            }
            throw URLError(.notConnectedToInternet)
        }
        let poller = makePoller()
        await poller.pollAll()
        XCTAssertNotEqual(poller.states().first?.status, .reloginNeeded)
        XCTAssertEqual(store.writes.count, 1) // refresh write-back happened despite the retry failing
        XCTAssertEqual(store.creds[acct.id]?.accessToken, "A2") // rotation persisted
    }

    func testNoCredentialsShowsNotLoggedIn() async {
        let poller = makePoller()
        await poller.pollAll()
        XCTAssertEqual(poller.states().first?.status, .notLoggedIn)
    }
}
