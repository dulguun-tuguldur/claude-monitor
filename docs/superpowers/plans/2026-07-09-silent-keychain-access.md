# Silent Keychain Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route `KeychainStore`'s secret reads and writes through `/usr/bin/security`
subprocesses instead of direct `SecItemCopyMatching`/`SecItemUpdate` calls, so
"Always Allow" grants survive rebuilds and restarts permanently.

**Architecture:** `KeychainStore` gains an injectable `SecurityCLIRunning` seam
(default: a real `Process`-backed runner). Attribute-only lookups (existence,
account name) stay on the direct `SecItemCopyMatching` API — they never touch
the secret and never prompt. Secret reads go through
`security find-generic-password -w`; secret writes go through
`security -i` (interactive mode) fed via stdin, so the token never appears in
argv/`ps`. The update-only invariant is preserved by resolving existence via
the unchanged attribute-only query before ever invoking `-U`.

**Tech Stack:** Swift 5.9+ (SPM), Foundation `Process`/`Pipe`, Security.framework
(unchanged for attribute-only queries), XCTest.

---

## Task 1: `SecurityCLIRunning` seam + read path via `security` CLI

**Files:**
- Modify: `Sources/MonitorCore/KeychainStore.swift`
- Test: `Tests/MonitorCoreTests/KeychainStoreTests.swift`

- [ ] **Step 1: Write the failing unit tests for the read path against a fake runner**

Add to `Tests/MonitorCoreTests/KeychainStoreTests.swift` (new test methods,
existing tests untouched for now):

```swift
struct FakeSecurityCLIRunner: SecurityCLIRunning {
    var response: (stdout: Data, exitCode: Int32)
    var onRun: ((_ arguments: [String], _ stdin: Data?) -> Void)?

    func run(arguments: [String], stdin: Data?) -> (stdout: Data, exitCode: Int32) {
        onRun?(arguments, stdin)
        return response
    }
}

extension KeychainStoreTests {
    func testReadDecodesPrintableCLIOutput() throws {
        addTestItem(service: prefix + "kc", Data())
        let json = try validCredsJSON()
        let fake = FakeSecurityCLIRunner(response: (json + Data("\n".utf8), 0))
        let store = KeychainStore(servicePrefixOverride: prefix, cliRunner: fake)
        let creds = try store.readCredentials(for: account)
        XCTAssertEqual(creds.accessToken, "sk-ant-oat01-FAKEFAKEFAKE")
    }

    func testReadDecodesHexCLIOutput() throws {
        addTestItem(service: prefix + "kc", Data())
        let json = try validCredsJSON()
        let hex = json.map { String(format: "%02x", $0) }.joined()
        let fake = FakeSecurityCLIRunner(response: (Data((hex + "\n").utf8), 0))
        let store = KeychainStore(servicePrefixOverride: prefix, cliRunner: fake)
        let creds = try store.readCredentials(for: account)
        XCTAssertEqual(creds.accessToken, "sk-ant-oat01-FAKEFAKEFAKE")
    }

    func testReadMapsExitCode44ToNotFound() throws {
        addTestItem(service: prefix + "kc", Data())
        let fake = FakeSecurityCLIRunner(response: (Data(), 44))
        let store = KeychainStore(servicePrefixOverride: prefix, cliRunner: fake)
        XCTAssertThrowsError(try store.readCredentials(for: account)) { error in
            XCTAssertEqual(error as? KeychainError, .notFound)
        }
    }

    func testReadMapsOtherExitCodesToOSStatus() throws {
        addTestItem(service: prefix + "kc", Data())
        let fake = FakeSecurityCLIRunner(response: (Data(), 1))
        let store = KeychainStore(servicePrefixOverride: prefix, cliRunner: fake)
        XCTAssertThrowsError(try store.readCredentials(for: account)) { error in
            XCTAssertEqual(error as? KeychainError, .osStatus(1))
        }
    }

    func testReadInvokesFindGenericPasswordWithService() throws {
        addTestItem(service: prefix + "kc", Data())
        var capturedArgs: [String] = []
        let fake = FakeSecurityCLIRunner(response: (try validCredsJSON() + Data("\n".utf8), 0),
                                          onRun: { args, _ in capturedArgs = args })
        let store = KeychainStore(servicePrefixOverride: prefix, cliRunner: fake)
        _ = try store.readCredentials(for: account)
        XCTAssertEqual(capturedArgs, ["find-generic-password", "-s", prefix + "kc", "-w"])
    }
}
```

`KeychainError` needs `Equatable` (already `Equatable` per its declaration —
confirm, no change needed).

- [ ] **Step 2: Run tests to verify they fail to compile (no `SecurityCLIRunning`/injectable init yet)**

Run: `swift test --filter KeychainStoreTests`
Expected: build error — `cannot find type 'SecurityCLIRunning' in scope` and
no matching `KeychainStore(servicePrefixOverride:cliRunner:)` initializer.

- [ ] **Step 3: Implement `SecurityCLIRunning`, the real runner, and the read path**

Replace the top of `Sources/MonitorCore/KeychainStore.swift` (imports through
the `readCredentials` function) with:

```swift
// ABOUTME: Reads and update-only-writes Claude Code credential items in the macOS
// ABOUTME: Keychain, resolving the per-CLAUDE_CONFIG_DIR service name per account.
import CryptoKit
import Foundation
import Security

public enum KeychainError: Error, Equatable { case notFound, osStatus(Int32) }

public protocol CredentialStore: Sendable {
    func readCredentials(for account: Account) throws -> Credentials
    func writeCredentials(_ data: Data, for account: Account) throws
}

/// Runs `/usr/bin/security` so credential access goes through the one process
/// every Keychain item already trusts permanently (its ACL/partition never
/// changes across our rebuilds), instead of the direct Security API, whose
/// "Always Allow" grant is pinned to our per-build code identity and expires
/// on every rebuild without a paid Developer ID team identifier.
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
        process.standardError = Pipe()
        let inPipe = stdin.map { _ in Pipe() }
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

    /// Attribute-only lookup — never touches the secret, so it never prompts.
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

    func resolveService(for account: Account) -> String? {
        resolveItem(for: account)?.service
    }

    public func readCredentials(for account: Account) throws -> Credentials {
        guard let service = resolveService(for: account) else { throw KeychainError.notFound }
        let (stdout, exitCode) = cliRunner.run(arguments: ["find-generic-password", "-s", service, "-w"], stdin: nil)
        guard exitCode == 0 else {
            throw exitCode == 44 ? KeychainError.notFound : KeychainError.osStatus(exitCode)
        }
        return try Credentials.parse(Self.decodeSecurityOutput(stdout))
    }

    /// `security -w` prints the secret as text when printable, or as hex when it
    /// isn't. Claude Code's credential JSON is printable, but this keeps us honest
    /// if that ever changes.
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
}
```

(The `writeCredentials` function from the original file is intentionally
omitted here — Task 2 replaces it. Leave the old direct-`SecItemUpdate`
`writeCredentials` in place for now so the file still compiles between Task 1
and Task 2.)

- [ ] **Step 4: Run tests to verify the new ones pass and old ones still pass**

Run: `swift test --filter KeychainStoreTests`
Expected: `testReadDecodesPrintableCLIOutput`, `testReadDecodesHexCLIOutput`,
`testReadMapsExitCode44ToNotFound`, `testReadMapsOtherExitCodesToOSStatus`,
`testReadInvokesFindGenericPasswordWithService` all PASS. Pre-existing tests
(`testReadViaServicePrefixSeam`, etc.) still PASS or FAIL only for reasons
addressed in Task 3 (real-Keychain integration tests need their fixture setup
updated to use the `security` CLI so the subprocess can read them) — if any of
the four pre-existing tests hang waiting on a GUI prompt, kill the run, this
is expected and fixed in Task 3; do not proceed past a hang.

- [ ] **Step 5: Commit**

```bash
git add Sources/MonitorCore/KeychainStore.swift Tests/MonitorCoreTests/KeychainStoreTests.swift
git commit -m "feat: read keychain credentials via security CLI subprocess"
```

---

## Task 2: Write path via `security -i` over stdin

**Files:**
- Modify: `Sources/MonitorCore/KeychainStore.swift`
- Test: `Tests/MonitorCoreTests/KeychainStoreTests.swift`

- [ ] **Step 1: Write the failing unit tests for the write path against a fake runner**

Add to `Tests/MonitorCoreTests/KeychainStoreTests.swift`:

```swift
extension KeychainStoreTests {
    func testWriteSendsCommandViaStdinNotArgv() throws {
        addTestItem(service: prefix + "kc", try validCredsJSON())
        var capturedArgs: [String] = []
        var capturedStdin: Data?
        let fake = FakeSecurityCLIRunner(response: (Data(), 0), onRun: { args, stdin in
            capturedArgs = args
            capturedStdin = stdin
        })
        let store = KeychainStore(servicePrefixOverride: prefix, cliRunner: fake)
        try store.writeCredentials(try validCredsJSON(), for: account)
        XCTAssertEqual(capturedArgs, ["-i"])
        let stdinText = String(data: capturedStdin ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(stdinText.contains("add-generic-password"))
        XCTAssertTrue(stdinText.contains("-U"))
        XCTAssertTrue(stdinText.contains(prefix + "kc"))
        XCTAssertFalse(capturedArgs.joined().contains("sk-ant-oat01"))
    }

    func testWriteThrowsNotFoundWithoutInvokingCLI() throws {
        // no item added
        var invoked = false
        let fake = FakeSecurityCLIRunner(response: (Data(), 0), onRun: { _, _ in invoked = true })
        let store = KeychainStore(servicePrefixOverride: prefix, cliRunner: fake)
        XCTAssertThrowsError(try store.writeCredentials(try validCredsJSON(), for: account)) { error in
            XCTAssertEqual(error as? KeychainError, .notFound)
        }
        XCTAssertFalse(invoked)
    }

    func testWriteMapsNonZeroExitToOSStatus() throws {
        addTestItem(service: prefix + "kc", try validCredsJSON())
        let fake = FakeSecurityCLIRunner(response: (Data(), 1))
        let store = KeychainStore(servicePrefixOverride: prefix, cliRunner: fake)
        XCTAssertThrowsError(try store.writeCredentials(try validCredsJSON(), for: account)) { error in
            XCTAssertEqual(error as? KeychainError, .osStatus(1))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter KeychainStoreTests`
Expected: `testWriteSendsCommandViaStdinNotArgv` FAILs (old implementation
still uses `SecItemUpdate`, never touches `cliRunner`, so `capturedArgs` stays
empty). `testWriteThrowsNotFoundWithoutInvokingCLI` and
`testWriteMapsNonZeroExitToOSStatus` may pass or fail depending on the old
code path — that's fine, Step 3 makes all three pass for the right reason.

- [ ] **Step 3: Replace `writeCredentials` to shell out via stdin**

Replace the old `writeCredentials` (the one still using `SecItemUpdate`) in
`Sources/MonitorCore/KeychainStore.swift` with:

```swift
    /// Update-only by design: the monitor must never create credential items,
    /// only rotate tokens inside items Claude Code already owns.
    public func writeCredentials(_ data: Data, for account: Account) throws {
        guard let item = resolveItem(for: account) else { throw KeychainError.notFound }
        guard let secretText = String(data: data, encoding: .utf8) else {
            throw KeychainError.osStatus(errSecParam)
        }
        let command = """
        add-generic-password -U -s \(Self.quoted(item.service)) -a \(Self.quoted(item.account)) -w \(Self.quoted(secretText))

        """
        let (_, exitCode) = cliRunner.run(arguments: ["-i"], stdin: Data(command.utf8))
        guard exitCode == 0 else {
            throw exitCode == 44 ? KeychainError.notFound : KeychainError.osStatus(exitCode)
        }
    }

    /// Quotes a value for `security -i`'s line-oriented command parser, which
    /// uses double-quote/backslash escaping like a shell word.
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter KeychainStoreTests`
Expected: `testWriteSendsCommandViaStdinNotArgv`,
`testWriteThrowsNotFoundWithoutInvokingCLI`, `testWriteMapsNonZeroExitToOSStatus`
all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MonitorCore/KeychainStore.swift Tests/MonitorCoreTests/KeychainStoreTests.swift
git commit -m "feat: write keychain credentials via security CLI over stdin"
```

---

## Task 3: Fix pre-existing integration tests to trust `/usr/bin/security`

**Files:**
- Modify: `Tests/MonitorCoreTests/KeychainStoreTests.swift`

**Why this task exists:** The pre-existing tests create fixture items with
`SecItemAdd` called directly from the XCTest process. A Keychain item's
default ACL only trusts the process that created it. Now that
`readCredentials`/`writeCredentials` access secrets via the `/usr/bin/security`
subprocess — a different signed binary than the test process — that
subprocess has no standing grant on test-created items and macOS will show a
blocking password prompt during `swift test`. Creating (and deleting) the
fixture through the `security` CLI itself makes `/usr/bin/security` the
creator, which is trusted by default — matching how real Claude Code items
already work.

- [ ] **Step 1: Replace `addTestItem` and `tearDown` to use the `security` CLI**

In `Tests/MonitorCoreTests/KeychainStoreTests.swift`, replace:

```swift
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
```

with:

```swift
    func runSecurityCLI(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try! process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func addTestItem(service: String, _ data: Data) {
        let secret = String(data: data, encoding: .utf8) ?? ""
        let status = runSecurityCLI(["add-generic-password", "-U", "-s", service,
                                      "-a", NSUserName(), "-w", secret])
        XCTAssertEqual(status, 0)
    }

    override func tearDown() {
        _ = runSecurityCLI(["delete-generic-password", "-s", prefix + "kc"])
    }
```

- [ ] **Step 2: Run the full pre-existing test suite to verify no prompts and all pass**

Run: `swift test --filter KeychainStoreTests`
Expected: all tests PASS with no interactive prompt and no hang, including
`testReadViaServicePrefixSeam`, `testWriteUpdatesExistingItem`,
`testWriteNeverCreatesItems`, `testReadMissingThrowsNotFound`,
`testCandidateServicesUsesSHA256PathPrefixForNonDefaultAccount`, and all tests
added in Tasks 1–2.

If a prompt still appears: stop and re-check the ACL on the offending test
item with `security dump-keychain -a ~/Library/Keychains/login.keychain-db |
grep -A20 '"<prefix>kc"'` before changing anything else — do not disable or
skip the test.

- [ ] **Step 3: Commit**

```bash
git add Tests/MonitorCoreTests/KeychainStoreTests.swift
git commit -m "test: create keychain fixtures via security CLI so subprocess reads don't prompt"
```

---

## Task 4: Full suite + manual verification against the real installed app

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `swift test`
Expected: all tests PASS (unit + integration), no hangs, no prompts.

- [ ] **Step 2: Run the e2e suite**

Run: `make e2e`
Expected: exits 0. (E2E fixtures already go through the `security` CLI per
the existing spike, so this should be unaffected by the change.)

- [ ] **Step 3: Rebuild and reinstall the app, then manually verify silence across a rebuild**

```bash
make app
```

Then manually, outside of any test harness: quit the running
`Claude Monitor.app`, relaunch it, and confirm no Keychain dialog appears for
any of the six accounts. Rebuild with `make app` again (changing the binary's
cdhash) and relaunch once more — confirm still no dialog. This is the
regression `make e2e`/unit tests cannot observe (they don't drive the real
GUI dialog path), so it must be checked by hand once before calling the
fix done.

Expected: zero dialogs on both launches, for all six accounts, except the
already-documented one-time prompt on `Claude Code-credentials-ce2d9f0a`
(see spec, "One-time user action") if it hasn't already been granted.

- [ ] **Step 4: Update the design spec status (optional but recommended)**

No file changes required; this step is a checkpoint to confirm with Mr. D
that the manual verification in Step 3 passed before considering the branch
done.

---

## Self-Review Notes

- **Spec coverage:** read path (Task 1), write path (Task 2), update-only
  invariant preserved via `resolveItem` (Task 2), stdin-not-argv (Task 2 test
  `testWriteSendsCommandViaStdinNotArgv`), exit-code mapping (Tasks 1–2),
  hex-decode fallback (Task 1), untouched `CM_KEYCHAIN_SERVICE_PREFIX` seam
  and E2E fixtures (Task 4), one-time prompt caveat (Task 4 manual step) — all
  covered.
- **Type consistency:** `SecurityCLIRunning.run(arguments:stdin:) ->
  (stdout: Data, exitCode: Int32)` is the same signature used by
  `ProcessSecurityCLIRunner`, `FakeSecurityCLIRunner`, and both call sites in
  `KeychainStore`. `KeychainError.osStatus` takes `Int32` throughout (matches
  `Process.terminationStatus`'s type) — note this is a signature change from
  the original `osStatus(OSStatus)` (`OSStatus` is itself `Int32` under the
  hood, so no call-site breakage, but flagging since callers pattern-matching
  on `.osStatus` don't care about the underlying type name).
