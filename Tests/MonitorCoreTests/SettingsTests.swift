// ABOUTME: Tests settings persistence round-trips and defaults using an
// ABOUTME: isolated UserDefaults suite that is wiped per test.
import XCTest
@testable import MonitorCore

final class SettingsTests: XCTestCase {
    var suite: String!
    var settings: Settings!

    override func setUp() {
        suite = "cm-tests-\(UUID().uuidString)"
        settings = Settings(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() { UserDefaults().removePersistentDomain(forName: suite) }

    func testDefaults() {
        XCTAssertNil(settings.selectedAccountId)
        XCTAssertEqual(settings.pollIntervalSeconds, 60)
        XCTAssertTrue(settings.hiddenAccountIds.isEmpty)
        XCTAssertTrue(settings.showSessionResetTime)
    }

    func testRoundTrip() {
        settings.selectedAccountId = "/Users/x/.claude-me"
        settings.pollIntervalSeconds = 120
        settings.hiddenAccountIds = ["/Users/x/.claude-backup"]
        XCTAssertEqual(settings.selectedAccountId, "/Users/x/.claude-me")
        XCTAssertEqual(settings.pollIntervalSeconds, 120)
        XCTAssertEqual(settings.hiddenAccountIds, ["/Users/x/.claude-backup"])
    }

    func testSessionResetTimeCanBeHidden() {
        settings.showSessionResetTime = false
        XCTAssertFalse(settings.showSessionResetTime)
        settings.showSessionResetTime = true
        XCTAssertTrue(settings.showSessionResetTime)
    }

    func testIntervalFloor() {
        settings.pollIntervalSeconds = 5
        XCTAssertEqual(settings.pollIntervalSeconds, 15) // floor protects the API
    }
}
