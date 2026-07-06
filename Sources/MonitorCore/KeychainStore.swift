// ABOUTME: Reads and update-only-writes Claude Code credential items in the macOS
// ABOUTME: Keychain, resolving the per-CLAUDE_CONFIG_DIR service name per account.
import CryptoKit
import Foundation
import Security

public enum KeychainError: Error, Equatable { case notFound, osStatus(OSStatus) }

public protocol CredentialStore: Sendable {
    func readCredentials(for account: Account) throws -> Credentials
    func writeCredentials(_ data: Data, for account: Account) throws
}

public struct KeychainStore: CredentialStore {
    let servicePrefixOverride: String?

    public init(servicePrefixOverride: String? = ProcessInfo.processInfo.environment["CM_KEYCHAIN_SERVICE_PREFIX"]) {
        self.servicePrefixOverride = servicePrefixOverride
    }

    /// Candidate service names, tried in order. For non-default accounts, Claude Code
    /// suffixes the service name with the first 8 hex characters of the SHA-256 digest
    /// of the config dir's absolute path (confirmed against real Keychain entries and
    /// daemon roster files — see `spike-results.md`). No cross-account fallback: a
    /// non-default dir must never resolve to the default entry, or accounts would show
    /// each other's data.
    func candidateServices(for account: Account) -> [String] {
        // Test/E2E seam: service name is simply "<prefix><label>".
        if let prefix = servicePrefixOverride { return [prefix + account.label] }
        let isDefault = account.configDir.lastPathComponent == ".claude"
        if isDefault { return ["Claude Code-credentials"] }
        let digest = SHA256.hash(data: Data(account.configDir.path.utf8))
        let suffix = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(8)
        return ["Claude Code-credentials-\(suffix)"]
    }

    func resolveService(for account: Account) -> String? {
        for service in candidateServices(for: account) {
            var out: CFTypeRef?
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnAttributes as String: true,
            ]
            if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess { return service }
        }
        return nil
    }

    public func readCredentials(for account: Account) throws -> Credentials {
        guard let service = resolveService(for: account) else { throw KeychainError.notFound }
        var out: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            throw status == errSecItemNotFound ? KeychainError.notFound : KeychainError.osStatus(status)
        }
        return try Credentials.parse(data)
    }

    /// Update-only by design: the monitor must never create credential items,
    /// only rotate tokens inside items Claude Code already owns.
    public func writeCredentials(_ data: Data, for account: Account) throws {
        guard let service = resolveService(for: account) else { throw KeychainError.notFound }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else {
            throw status == errSecItemNotFound ? KeychainError.notFound : KeychainError.osStatus(status)
        }
    }
}
