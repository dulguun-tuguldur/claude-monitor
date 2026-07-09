# Silent Keychain Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route `KeychainStore`'s secret reads and writes through `/usr/bin/security`
subprocesses instead of direct `SecItemCopyMatching`/`SecItemUpdate` calls, so
"Always Allow" grants survive rebuilds and restarts permanently.

**Architecture:** `KeychainStore` gains an injectable `SecurityCLIRunning` seam
(default: a real `Process`-backed runner). Attribute-only lookups (existence +
account name) stay on the direct `SecItemCopyMatching` API — they never touch
the secret and never prompt. Secret reads go through
`security find-generic-password -w`; secret writes go through `security -i`
(interactive mode) fed via stdin so the token never appears in argv/`ps`. The
update-only invariant is preserved by resolving existence via the unchanged
attribute-only query before ever invoking `-U`.

**Tech Stack:** Swift 5.9+ (SPM), Foundation `Process`/`Pipe`, Security.framework
(unchanged for attribute-only queries), XCTest.

---

## Spike findings (verified 2026-07-09, on a disposable throwaway item)

These are confirmed, not assumed — the code below depends on each:

1. **`security find-generic-password -w`** prints the secret as printable text
   when printable (our JSON always is — it starts with `{`), with a **single
   trailing `\n`** that must be trimmed. It prints **hex** only when the blob is
   non-printable; the hex fallback below is defensive and can never misfire on
   valid Claude JSON (which starts with `{`, not a hex digit).
2. **`security -i` fed `add-generic-password -U -s "…" -a "…" -w "<escaped JSON>"`
   on stdin round-trips byte-identically**, including embedded `"` and `\`, using
   the `quoted()` escaping (`\`→`\\`, `"`→`\"`, wrap in `"`). Secret stays off argv.
3. **`add-generic-password -U` preserves the existing item's ACL and partition
   list entirely** (all ACL entries byte-identical before/after). Rotating a
   token therefore does **not** disturb Claude Code's own access — the monitor
   stays a good citizen.
4. **Exit codes:** `0` = success; `44` = item not found (`errSecItemNotFound`).
   Other non-zero = failure.
5. Writing is unrestricted anyway (the items' `encrypt` ACL entry has
   `applications: <null>`), but routing writes through the CLI keeps the code
   path uniform and guarantees no partition-check prompt on a rebuilt binary.

## File structure

Only one production file and its test change. Responsibilities:

- `Sources/MonitorCore/KeychainStore.swift` — owns the `CredentialStore`
  protocol, the internal `SecurityCLIRunning` seam + default `Process` runner,
  service-name resolution (attribute-only, non-prompting), and the read/write
  secret paths via the `security` CLI.
- `Tests/MonitorCoreTests/KeychainStoreTests.swift` — unit tests against a fake
  runner (no keychain needed for CLI behavior) plus real-keychain integration
  tests whose fixtures are created through the `security` CLI so the subprocess
  can read them without a prompt.

---

## Task 1: `SecurityCLIRunning` seam + read path via `security` CLI

**Files:**
- Modify: `Sources/MonitorCore/KeychainStore.swift`
- Test: `Tests/MonitorCoreTests/KeychainStoreTests.swift`

- [ ] **Step 1: Write the failing unit tests for the read path against a fake runner**

Add to `Tests/MonitorCoreTests/KeychainStoreTests.swift` (new methods; existing
tests untouched for now):

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
        addTestItem(service: prefix + "kc", try validCredsJSON())
        let json = try validCredsJSON()
        let fake = FakeSecurityCLIRunner(response: (json + Data("\n".utf8), 0))
        let store = KeychainStore(servicePrefixOverride: prefix, cliRunner: fake)
        let creds = try store.readCredentials(for: account)
        XCTAssertEqual(creds.accessToken, "sk-ant-oat01-FAKEFAKEFAKE")
    }

    func testReadDecodesHexCLIOutput() throws {
        addTestItem(service: prefix + "kc", try validCredsJSON())
        let json = try validCredsJSON()
        let hex = json.map { String(format: "%02x", $0) }.joined()
        let fake = FakeSecurityCLIRunner(response: (Data((hex + "\n").utf8), 0))
        let store = KeychainStore(servicePrefixOverride: prefix, cliRunner: fake)
        let creds = try store.readCredentials(for: account)
        XCTAssertEqual(creds.accessToken, "sk-ant-oat01-FAKEFAKEFAKE")
    }

    func testReadMapsExitCode44ToNotFound() throws {
        addTestItem(service: prefix + "kc", try validCredsJSON())
        let fake = FakeSecurityCLIRunner(response: (Data(), 44))
        let store = KeychainStore(servicePrefixOverride: prefix, cliRunner: fake)
        XCTAssertThrowsError(try store.readCredentials(for: account)) { error in
            XCTAssertEqual(error as? KeychainError, .notFound)
        }
    }

    func testReadMapsOtherExitCodesToOSStatus() throws {
        addTestItem(service: prefix + "kc", try validCredsJSON())
        let fake = FakeSecurityCLIRunner(response: (Data(), 1))
        let store = KeychainStore(servicePrefixOverride: prefix, cliRunner: fake)
        XCTAssertThrowsError(try store.readCredentials(for: account)) { error in
            XCTAssertEqual(error as? KeychainError, .osStatus(1))
        }
    }

    func testReadInvokesFindGenericPasswordWithService() throws {
        addTestItem(service: prefix + "kc", try validCredsJSON())
        var capturedArgs: [String] = []
        let fake = FakeSecurityCLIRunner(response: (try validCredsJSON() + Data("\n".utf8), 0),
                                          onRun: { args, _ in capturedArgs = args })
        let store = KeychainStore(servicePrefixOverride: prefix, cliRunner: fake)
        _ = try store.readCredentials(for: account)
        XCTAssertEqual(capturedArgs, ["find-generic-password", "-s", prefix + "kc", "-w"])
    }
}
```

Note: `addTestItem` still uses `SecItemAdd` at this point. That's fine for these
tests — they read through the **fake** runner, and `resolveItem`'s
attribute-only `SecItemCopyMatching` finds a `SecItemAdd`-created item without
prompting. The real-runner fixture change comes in Task 3.

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `swift test --filter KeychainStoreTests`
Expected: build error — `cannot find type 'SecurityCLIRunning' in scope` and no
matching `KeychainStore(servicePrefixOverride:cliRunner:)` initializer.

- [ ] **Step 3: Implement the seam, the default runner, resolution, and the read path**

Replace the entire contents of `Sources/MonitorCore/KeychainStore.swift` from
the top through the `readCredentials` function — i.e. everything **except** the
existing `writeCredentials` function, which stays in place for now so the file
still compiles (Task 2 replaces it). Concretely, replace lines from the file
header down to the end of `readCredentials` with:

```swift
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
```

Note the change from the original: `resolveService` is gone; `resolveItem`
replaces it (grep confirmed `resolveService` had no callers outside this file).
The exit code is `Int32`, which is exactly what `OSStatus` is a typealias for,
so `KeychainError.osStatus(exitCode)` needs no cast and the enum is unchanged.

- [ ] **Step 4: Run tests to verify the new read tests pass**

Run: `swift test --filter KeychainStoreTests`
Expected: `testReadDecodesPrintableCLIOutput`, `testReadDecodesHexCLIOutput`,
`testReadMapsExitCode44ToNotFound`, `testReadMapsOtherExitCodesToOSStatus`,
`testReadInvokesFindGenericPasswordWithService` all PASS.

The pre-existing integration tests may temporarily fail to compile if the old
`writeCredentials` referenced the now-removed `resolveService`. If so, minimally
patch that one line in the old `writeCredentials` to `resolveItem(for: account)?.service`
so the file compiles; Task 2 rewrites the whole function anyway. Do NOT change
any other behavior. If a pre-existing **integration** test (real runner) hangs
on a GUI prompt, kill the run — that is expected until Task 3 and is not a
regression.

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
        let secret = try validCredsJSON()
        try store.writeCredentials(secret, for: account)
        XCTAssertEqual(capturedArgs, ["-i"])
        let stdinText = String(data: capturedStdin ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(stdinText.contains("add-generic-password"))
        XCTAssertTrue(stdinText.contains("-U"))
        XCTAssertTrue(stdinText.contains(prefix + "kc"))
        // Secret must ride on stdin, never argv.
        XCTAssertFalse(capturedArgs.joined().contains("sk-ant-oat01"))
        XCTAssertTrue(stdinText.contains("sk-ant-oat01"))
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
Expected: `testWriteSendsCommandViaStdinNotArgv` FAILs — the old `writeCredentials`
uses `SecItemUpdate` and never touches `cliRunner`, so `capturedArgs`/`capturedStdin`
stay empty. The other two may pass or fail incidentally; Step 3 makes all three
pass for the right reason.

- [ ] **Step 3: Replace `writeCredentials` to shell out via `security -i` over stdin**

Replace the entire existing `writeCredentials` function (the one still using
`SecItemUpdate`) in `Sources/MonitorCore/KeychainStore.swift` with:

```swift
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

**Why this task exists:** The pre-existing integration tests
(`testReadViaServicePrefixSeam`, `testWriteUpdatesExistingItem`) use the **real**
runner (default init), so they invoke the actual `security` binary against the
fixture item. A Keychain item's default ACL trusts only the process that created
it. Fixtures are currently created with `SecItemAdd` from the XCTest process, so
the `security` subprocess is **not** on their decrypt ACL and macOS shows a
blocking GUI prompt → the test hangs. Creating the fixture through the `security`
CLI instead makes `/usr/bin/security` the item's owner (its decrypt ACL then
lists `com.apple.security`, and reads via the CLI succeed silently — verified in
the 2026-07-09 spike), matching how real Claude Code items already work.

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
    @discardableResult
    func runSecurityCLI(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = FileHandle.nullDevice
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
        runSecurityCLI(["delete-generic-password", "-s", prefix + "kc"])
    }
```

- [ ] **Step 2: Run the full KeychainStore suite to verify no prompts and all pass**

Run: `swift test --filter KeychainStoreTests`
Expected: all tests PASS with no interactive prompt and no hang — the unit tests
from Tasks 1–2 (fake runner), plus the integration tests
`testReadViaServicePrefixSeam`, `testWriteUpdatesExistingItem`,
`testWriteNeverCreatesItems`, `testReadMissingThrowsNotFound`, and
`testCandidateServicesUsesSHA256PathPrefixForNonDefaultAccount`.

If a prompt still appears: STOP. Do not skip or disable the test. Inspect the
offending item's ACL first — `security dump-keychain -a
~/Library/Keychains/login.keychain-db` and search for the test service name —
to see which app the decrypt ACL trusts, then reconcile before continuing.

- [ ] **Step 3: Commit**

```bash
git add Tests/MonitorCoreTests/KeychainStoreTests.swift
git commit -m "test: create keychain fixtures via security CLI so subprocess reads don't prompt"
```

---

## Task 4: Full suite + manual verification against the real installed app

**Files:** none (verification only)

- [ ] **Step 1: Run the full unit/integration suite**

Run: `swift test`
Expected: all tests PASS, no hangs, no prompts.

- [ ] **Step 2: Run the e2e suite**

Run: `make e2e`
Expected: exits 0. (E2E fixtures already go through the `security` CLI per the
existing spike setup, so this path is unaffected by the change.)

- [ ] **Step 3: Rebuild, reinstall, and manually verify silence across a rebuild**

```bash
make app
```

Then, outside any test harness: quit the running `Claude Monitor.app`, relaunch
it, and confirm no Keychain dialog appears for any of the six accounts. Rebuild
with `make app` again (this changes the binary's cdhash — the exact condition
that used to re-trigger prompts) and relaunch once more; confirm still no dialog.
This is the regression neither unit nor e2e tests can observe, because they do
not drive the real GUI dialog path — so it must be checked by hand once before
declaring the fix done.

Expected: zero dialogs on both launches, for all six accounts — except the
already-documented one-time prompt on `Claude Code-credentials-ce2d9f0a` (see
spec, "One-time user action") if that grant has not yet been made. "Always Allow"
there binds to `/usr/bin/security` and is then permanent.

- [ ] **Step 4: Verification checkpoint**

No file changes. Confirm with Mr. D that Step 3's manual check passed (zero
dialogs across a rebuild) before the branch is considered done, then hand off to
the finishing-a-development-branch skill.

---

## Self-Review Notes

- **Spec coverage:** read path via CLI (Task 1); write path via CLI over stdin
  (Task 2); update-only invariant preserved via `resolveItem` existence gate
  (Task 2); secret off argv (Task 2 test `testWriteSendsCommandViaStdinNotArgv`);
  exit-code mapping incl. 44→notFound (Tasks 1–2); trailing-newline trim +
  hex-decode fallback (Task 1); untouched `CM_KEYCHAIN_SERVICE_PREFIX` seam and
  E2E path (Task 4); one-time `-ce2d9f0a` prompt caveat (Task 4 manual step);
  ACL-preserving write / good-citizen property (spike finding #3, relied on in
  Task 2's doc comment) — all covered.
- **Type consistency:** `SecurityCLIRunning.run(arguments:stdin:) ->
  (stdout: Data, exitCode: Int32)` matches across `ProcessSecurityCLIRunner`,
  `FakeSecurityCLIRunner`, and both `KeychainStore` call sites.
  `Process.terminationStatus` is `Int32`; `OSStatus` is a typealias for `Int32`;
  so `KeychainError.osStatus(exitCode)` compiles with the **unchanged** enum
  `case osStatus(OSStatus)` and no cast — the enum is not modified.
- **No dangling references:** `resolveService` is fully removed and every caller
  now uses `resolveItem`; `candidateServices` (the only externally tested helper)
  is unchanged.
