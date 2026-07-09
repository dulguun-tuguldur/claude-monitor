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

/// Runs `/usr/bin/security` so credential access goes through the one process
/// every Keychain item already trusts permanently: its ACL lists
/// `com.apple.security` and its partition list carries `apple-tool:`, neither of
/// which changes across our rebuilds. The direct Security API instead pins its
/// "Always Allow" grant to our per-build code identity, which changes on every
/// rebuild without a paid Developer ID team identifier, causing a re-prompt.
protocol SecurityCLIRunning: Sendable {
    func run(arguments: [String], stdin: Data?) -> (stdout: Data, exitCode: Int32)
}

struct ProcessSecurityCLIRunner: SecurityCLIRunning {
    func run(arguments: [String], stdin: Data?) -> (stdout: Data, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        let inPipe: Pipe? = (stdin != nil) ? Pipe() : nil
        if let inPipe { process.standardInput = inPipe }
        do {
            try process.run()
        } catch {
            return (Data(), -1)
        }
        if let stdin, let inPipe {
            inPipe.fileHandleForWriting.write(stdin)
            inPipe.fileHandleForWriting.closeFile()
        }
        let stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (stdout, process.terminationStatus)
    }
}

public struct KeychainStore: CredentialStore {
    let servicePrefixOverride: String?
    let cliRunner: SecurityCLIRunning

    public init(servicePrefixOverride: String? = ProcessInfo.processInfo.environment["CM_KEYCHAIN_SERVICE_PREFIX"]) {
        self.init(servicePrefixOverride: servicePrefixOverride, cliRunner: ProcessSecurityCLIRunner())
    }

    init(servicePrefixOverride: String?, cliRunner: SecurityCLIRunning) {
        self.servicePrefixOverride = servicePrefixOverride
        self.cliRunner = cliRunner
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

    /// Attribute-only lookup of the item's service + account name. Returns
    /// attributes, never the secret, so it never triggers a Keychain prompt.
    /// The account name is needed so a write can target the exact existing item.
    func resolveItem(for account: Account) -> (service: String, account: String)? {
        for service in candidateServices(for: account) {
            var out: CFTypeRef?
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnAttributes as String: true,
            ]
            if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
               let attrs = out as? [String: Any],
               let acct = attrs[kSecAttrAccount as String] as? String {
                return (service, acct)
            }
        }
        return nil
    }

    public func readCredentials(for account: Account) throws -> Credentials {
        guard let item = resolveItem(for: account) else { throw KeychainError.notFound }
        let (stdout, exitCode) = cliRunner.run(
            arguments: ["find-generic-password", "-s", item.service, "-w"], stdin: nil)
        guard exitCode == 0 else {
            throw exitCode == 44 ? KeychainError.notFound : KeychainError.osStatus(exitCode)
        }
        return try Credentials.parse(Self.decodeSecurityOutput(stdout))
    }

    /// `security -w` prints the secret as text when printable and as hex when it
    /// isn't. Claude Code's credential JSON is printable (starts with `{`, never a
    /// hex digit), so the hex branch is a defensive fallback that cannot misfire
    /// on valid input.
    static func decodeSecurityOutput(_ raw: Data) -> Data {
        var trimmed = raw
        while let last = trimmed.last, last == 0x0a || last == 0x0d { trimmed.removeLast() }
        if let hexDecoded = hexDecoded(trimmed) { return hexDecoded }
        return trimmed
    }

    static func hexDecoded(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8),
              !text.isEmpty, text.count % 2 == 0,
              text.allSatisfy(\.isHexDigit)
        else { return nil }
        var bytes = [UInt8]()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// Update-only by design: the monitor must never create credential items,
    /// only rotate tokens inside items Claude Code already owns. `resolveItem`
    /// gates on existence first so the `-U` below can never create a new item.
    /// `add-generic-password -U` preserves the item's ACL/partition, so rotating
    /// a token does not disturb Claude Code's own access.
    public func writeCredentials(_ data: Data, for account: Account) throws {
        guard let item = resolveItem(for: account) else { throw KeychainError.notFound }
        guard let secretText = String(data: data, encoding: .utf8) else {
            throw KeychainError.osStatus(errSecParam)
        }
        // The secret rides on stdin (interactive mode), never argv, so it is
        // never visible in `ps`.
        let command = "add-generic-password -U -s \(Self.quoted(item.service))"
            + " -a \(Self.quoted(item.account)) -w \(Self.quoted(secretText))\n"
        let (_, exitCode) = cliRunner.run(arguments: ["-i"], stdin: Data(command.utf8))
        guard exitCode == 0 else {
            throw exitCode == 44 ? KeychainError.notFound : KeychainError.osStatus(exitCode)
        }
    }

    /// Quotes a value for `security -i`'s line parser, which uses double-quote /
    /// backslash escaping like a shell word. Verified to round-trip JSON with
    /// embedded quotes and backslashes.
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
