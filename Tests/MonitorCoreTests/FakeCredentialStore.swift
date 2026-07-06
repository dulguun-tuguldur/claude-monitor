// ABOUTME: In-memory CredentialStore for Poller tests: canned credentials per
// ABOUTME: account plus a write log to assert refresh write-backs.
import Foundation
@testable import MonitorCore

final class FakeCredentialStore: CredentialStore, @unchecked Sendable {
    var creds: [String: Credentials] = [:]      // key: account.id
    var writes: [(id: String, data: Data)] = []

    func readCredentials(for account: Account) throws -> Credentials {
        guard let c = creds[account.id] else { throw KeychainError.notFound }
        return c
    }

    func writeCredentials(_ data: Data, for account: Account) throws {
        guard creds[account.id] != nil else { throw KeychainError.notFound }
        writes.append((account.id, data))
        creds[account.id] = try Credentials.parse(data)
    }
}
