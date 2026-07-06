// ABOUTME: Integration tests against the real macOS Keychain using disposable
// ABOUTME: test items; verifies read, update-only write, and not-found behavior.
import XCTest
import Security
@testable import MonitorCore

final class KeychainStoreTests: XCTestCase {
    let prefix = "cm-test-\(UUID().uuidString)-"
    var account: Account { Account(configDir: URL(fileURLWithPath: "/tmp/.claude-kc")) }

    func addTestItem(service: String, _ data: Data) {
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName(),
            kSecValueData as String: data,
        ]
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
    }

    override func tearDown() {
        let del: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: prefix + "kc"]
        SecItemDelete(del as CFDictionary)
    }

    func validCredsJSON() throws -> Data {
        try Data(contentsOf: Bundle.module.url(forResource: "credentials-valid", withExtension: "json", subdirectory: "Fixtures")!)
    }

    func testReadViaServicePrefixSeam() throws {
        addTestItem(service: prefix + "kc", try validCredsJSON())
        let store = KeychainStore(servicePrefixOverride: prefix)
        let creds = try store.readCredentials(for: account)
        XCTAssertEqual(creds.accessToken, "sk-ant-oat01-FAKEFAKEFAKE")
    }

    func testWriteUpdatesExistingItem() throws {
        addTestItem(service: prefix + "kc", try validCredsJSON())
        let store = KeychainStore(servicePrefixOverride: prefix)
        let creds = try store.readCredentials(for: account)
        let updated = try creds.updatedJSON(accessToken: "A2", refreshToken: "R2",
                                            expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
        try store.writeCredentials(updated, for: account)
        XCTAssertEqual(try store.readCredentials(for: account).accessToken, "A2")
    }

    func testWriteNeverCreatesItems() throws {
        let store = KeychainStore(servicePrefixOverride: prefix) // no item added
        XCTAssertThrowsError(try store.writeCredentials(try validCredsJSON(), for: account))
    }

    func testReadMissingThrowsNotFound() {
        let store = KeychainStore(servicePrefixOverride: prefix)
        XCTAssertThrowsError(try store.readCredentials(for: account))
    }

    /// Claude Code names non-default accounts' Keychain items using the first 8 hex
    /// characters of the SHA-256 digest of the config dir's absolute path — confirmed
    /// against real Keychain entries and daemon roster files, not the raw path or
    /// directory basename.
    func testCandidateServicesUsesSHA256PathPrefixForNonDefaultAccount() {
        let store = KeychainStore(servicePrefixOverride: nil)
        let nonDefault = Account(configDir: URL(fileURLWithPath: "/Users/dulguun/.claude-me"))
        XCTAssertEqual(store.candidateServices(for: nonDefault), ["Claude Code-credentials-9b72ce99"])
    }
}
