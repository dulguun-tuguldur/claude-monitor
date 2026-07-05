# Claude Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu bar app showing the selected Claude Code account's session / weekly / Sonnet usage percentages, with a dropdown to view and switch between all six accounts and a settings window.

**Architecture:** Swift Package (no Xcode project) with a UI-free `MonitorCore` library (account discovery, Keychain, OAuth refresh, usage API, formatting, polling) and a thin `ClaudeMonitor` executable (AppKit `NSStatusItem` + `NSMenu`, SwiftUI settings window). A script bundles the release binary into `Claude Monitor.app` for launch-at-login.

**Tech Stack:** Swift 5.9+ (SPM), AppKit + SwiftUI, Security.framework (Keychain), XCTest, bash + python3 for the E2E stub server.

---

## Context (why this exists)

Mr. D runs **six Claude Code accounts** via `CLAUDE_CONFIG_DIR` aliases (`claude-me`, `claude-tergel`, …) to spread usage across subscriptions. Deciding *which* account to use next means running `/usage` inside each one. This app puts the `/usage` numbers for all accounts in the menu bar: the selected account renders as `✳ 42·18·9` (session% · week% · sonnet%), the dropdown lists every account, clicking an account makes it the bar account, and Settings configures interval/hidden accounts/launch-at-login.

**Decisions locked during brainstorming (2026-07-05):**
- Native Swift/SwiftUI app, **SPM package** (not Xcode project). CLI-first: `swift build` / `swift test`.
- Bar layout: **compact triple** `✳ 42·18·9`, fixed order session · week(all) · week(sonnet). Colors: default <70%, orange ≥70%, red ≥90%; gray = stale/missing.
- **Auto-refresh expired tokens** (same OAuth flow Claude Code uses) with guardrails: only refresh already-expired tokens, single-flight per account, update-only atomic Keychain write-back preserving unknown JSON fields. Monitor never *creates* credential items.
- Notifications: **not in v1**.
- Accounts labeled by **folder suffix** (`main`, `me`, `boldoo`, `naraa`, `tergel`, `tushig`) — emails in `.claude.json` are stale copies and must not be used as identity.

**Verified facts (explored 2026-07-05):**
- Config dirs: `~/.claude` + `~/.claude-{me,boldoo,naraa,tergel,tushig}` (plus `-backup`, `-backup2` which must show as "not logged in" / hideable, since they contain `.claude.json` but were never logged in).
- **No `.credentials.json` anywhere** → credentials are in the macOS **Keychain**, necessarily one entry per config dir (boldoo/naraa are provably different accounts).
- Aliases: `alias claude-me="CLAUDE_CONFIG_DIR=~/.claude-me .../bin/claude"` (`~/.zshrc:137-141`).

**Open unknowns → resolved by Task 0 spike (permission-gated, needs Mr. D):**
1. Exact Keychain **service/account naming** per config dir (`security` lookups were denied to the agent by policy — the user runs one command).
2. Exact **usage endpoint response shape** (`GET https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`) — captured and sanitized into test fixtures.
3. Token refresh endpoint (`POST https://console.anthropic.com/v1/oauth/token`, client_id `9d1c250a-e61b-44d9-88ed-5944d1962f5e` — Claude Code's public OAuth client id). **Do not test-refresh during the spike** (refresh rotates tokens); it is live-tested on one guinea-pig account in Task 12.

Where spike results differ from the assumptions baked into code below, **the only files to touch are**: `KeychainStore.candidateServices` (naming), `UsageSnapshot` key constants (response keys), `TokenRefresher` (URL/client id), and the fixtures.

---

## File structure

```
~/me/claude/monitor/
├── Package.swift
├── CLAUDE.md                      # project instructions; assistant name: FRIDAY
├── social.md                      # journaling per Mr. D's global CLAUDE.md
├── README.md
├── Makefile
├── .gitignore
├── docs/superpowers/
│   ├── specs/2026-07-05-claude-monitor-design.md
│   └── plans/2026-07-05-claude-monitor.md      # this plan, copied in
├── scripts/
│   ├── spike.sh                   # Task 0 capture helper
│   ├── make-app.sh                # bundle .app
│   └── e2e.sh                     # end-to-end test
├── Sources/
│   ├── MonitorCore/
│   │   ├── Account.swift          # model + discovery
│   │   ├── Credentials.swift      # keychain JSON parse/expiry/write-back
│   │   ├── KeychainStore.swift    # CredentialStore protocol + real impl
│   │   ├── UsageSnapshot.swift    # usage API response model
│   │   ├── UsageClient.swift      # GET usage endpoint
│   │   ├── TokenRefresher.swift   # OAuth refresh
│   │   ├── BarFormatter.swift     # "42·18·9" segments + levels
│   │   ├── Settings.swift         # UserDefaults suite
│   │   └── Poller.swift           # engine: discover→read→refresh→fetch→publish
│   └── ClaudeMonitor/
│       ├── main.swift             # --print-once mode + app bootstrap
│       ├── StatusItemController.swift
│       └── SettingsWindow.swift
└── Tests/MonitorCoreTests/
    ├── AccountDiscoveryTests.swift
    ├── CredentialsTests.swift
    ├── UsageSnapshotTests.swift
    ├── BarFormatterTests.swift
    ├── KeychainStoreTests.swift   # integration: real keychain, test items
    ├── HTTPClientTests.swift      # UsageClient + TokenRefresher via MockURLProtocol
    ├── SettingsTests.swift
    ├── PollerTests.swift
    ├── MockURLProtocol.swift
    ├── FakeCredentialStore.swift
    └── Fixtures/
        ├── usage-full.json
        ├── usage-no-sonnet.json
        ├── credentials-valid.json
        └── credentials-expired.json
```

**Test seams (env vars, also used by spike/E2E):** `CM_CLAUDE_ROOT` (discovery root override), `CM_KEYCHAIN_SERVICE_PREFIX` (service = `<prefix><label>`), `CM_USAGE_URL`, `CM_TOKEN_URL`.

---

### Task 0: Bootstrap, spike, fixtures

**Files:** Create: `Package.swift`, `.gitignore`, `CLAUDE.md`, `social.md`, `docs/superpowers/specs/2026-07-05-claude-monitor-design.md`, `docs/superpowers/plans/2026-07-05-claude-monitor.md`, `scripts/spike.sh`, `Tests/MonitorCoreTests/Fixtures/*.json`

- [ ] **Step 0.1: git init + skeleton**

```bash
cd ~/me/claude/monitor
git init
mkdir -p Sources/MonitorCore Sources/ClaudeMonitor Tests/MonitorCoreTests/Fixtures scripts docs/superpowers/specs docs/superpowers/plans
```

- [ ] **Step 0.2: Write `Package.swift`**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "claude-monitor",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MonitorCore"),
        .executableTarget(name: "ClaudeMonitor", dependencies: ["MonitorCore"]),
        .testTarget(
            name: "MonitorCoreTests",
            dependencies: ["MonitorCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

- [ ] **Step 0.3: Write `.gitignore`**

```
.build/
*.app
.DS_Store
spike-raw/
```

`spike-raw/` holds raw spike captures **containing live tokens — never committed**.

- [ ] **Step 0.4: Write `CLAUDE.md`** — project name Claude Monitor, assistant name **FRIDAY** (per global CLAUDE.md: pick a name when starting a project), build/test commands (`make test`, `make e2e`, `make run`), pointer to spec + plan in `docs/superpowers/`. Also create `social.md` with a dated first entry.

- [ ] **Step 0.5: Copy spec + plan into repo** — spec = the *Context*, *Decisions*, *File structure* sections of this plan reshaped as the design doc; plan = this file verbatim.

- [ ] **Step 0.6: Spike — Keychain naming (Mr. D runs this, agent must not)**

Ask Mr. D to run in the Claude Code prompt:

```
! security dump-keychain | grep -i -B1 -A3 "claude" | grep -E '"svce"|"acct"' | sort -u
```

Record the service-name pattern per config dir in `docs/superpowers/specs/spike-results.md` (names only, no secrets). Expected shape: a distinct generic-password service per config dir (e.g. `Claude Code-credentials` for `~/.claude` and a suffixed variant for `CLAUDE_CONFIG_DIR` dirs). Update `KeychainStore.candidateServices` (Task 5) if the observed pattern differs from its candidate list.

- [ ] **Step 0.7: Spike — capture usage response** (`scripts/spike.sh`; reads one token via `security`, so Mr. D approves/runs it):

```bash
#!/usr/bin/env bash
# ABOUTME: Captures a real /usage API response for fixture-making.
# ABOUTME: Writes raw output to spike-raw/ (gitignored); sanitize before committing.
set -euo pipefail
SERVICE="${1:?usage: spike.sh <keychain-service-name>}"
mkdir -p spike-raw
TOKEN=$(security find-generic-password -s "$SERVICE" -w | python3 -c 'import sys,json;print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')
curl -sS https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "Accept: application/json" | python3 -m json.tool | tee spike-raw/usage-response.json
```

From the raw response, hand-write **sanitized** fixtures (structure identical, values fake). If key names differ from below, use the real ones and adjust the constants in Task 3.

- [ ] **Step 0.8: Write fixtures**

`Tests/MonitorCoreTests/Fixtures/usage-full.json`:

```json
{
  "five_hour":       { "utilization": 42.2, "resets_at": "2026-07-05T16:00:00Z" },
  "seven_day":       { "utilization": 18.0, "resets_at": "2026-07-08T00:00:00Z" },
  "seven_day_sonnet":{ "utilization": 9.4,  "resets_at": "2026-07-08T00:00:00Z" },
  "seven_day_opus":  { "utilization": 5.0,  "resets_at": "2026-07-08T00:00:00Z" },
  "some_future_field": { "ignored": true }
}
```

`usage-no-sonnet.json`: same minus `seven_day_sonnet`/`seven_day_opus`.

`credentials-valid.json` (fake tokens; `expiresAt` = 4102444800000 = year 2100):

```json
{
  "claudeAiOauth": {
    "accessToken": "sk-ant-oat01-FAKEFAKEFAKE",
    "refreshToken": "sk-ant-ort01-FAKEFAKEFAKE",
    "expiresAt": 4102444800000,
    "scopes": ["user:inference", "user:profile"],
    "subscriptionType": "max",
    "unknownField": "must-survive-writeback"
  }
}
```

`credentials-expired.json`: same with `"expiresAt": 1000000000000` (2001).

- [ ] **Step 0.9: Commit** — `git add -A && git commit -m "chore: bootstrap claude-monitor package, spike results, fixtures"`

---

### Task 1: Account model + discovery

**Files:** Create: `Sources/MonitorCore/Account.swift`, `Tests/MonitorCoreTests/AccountDiscoveryTests.swift`

- [ ] **Step 1.1: Write failing tests**

```swift
// ABOUTME: Tests account discovery: which ~/.claude* dirs become accounts,
// ABOUTME: how they are labeled, and the main-first sort order.
import XCTest
@testable import MonitorCore

final class AccountDiscoveryTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cm-test-\(UUID().uuidString)")
        for name in [".claude", ".claude-me", ".claude-backup", ".claude-empty"] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if name != ".claude-empty" {
                try Data("{}".utf8).write(to: dir.appendingPathComponent(".claude.json"))
            }
        }
        // decoys: unrelated dir and a plain file
        try FileManager.default.createDirectory(at: root.appendingPathComponent("claudius"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".claude-notadir"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testDiscoversOnlyClaudeDirsWithConfigJSON() {
        let labels = AccountDiscovery.discover(root: root).map(\.label)
        XCTAssertEqual(labels, ["main", "backup", "me"]) // main first, then alphabetical
    }

    func testLabelDerivation() {
        XCTAssertEqual(Account(configDir: URL(fileURLWithPath: "/x/.claude")).label, "main")
        XCTAssertEqual(Account(configDir: URL(fileURLWithPath: "/x/.claude-tergel")).label, "tergel")
    }
}
```

- [ ] **Step 1.2: Run** `swift test --filter AccountDiscoveryTests` → FAIL (types don't exist).
- [ ] **Step 1.3: Implement `Account.swift`**

```swift
// ABOUTME: Represents one Claude Code account (a CLAUDE_CONFIG_DIR) and discovers
// ABOUTME: accounts by scanning a root directory for .claude* config folders.
import Foundation

public struct Account: Equatable, Identifiable, Sendable {
    public let configDir: URL
    public let label: String
    public var id: String { configDir.path }

    public init(configDir: URL) {
        self.configDir = configDir
        let name = configDir.lastPathComponent
        self.label = name == ".claude" ? "main" : String(name.dropFirst(".claude-".count))
    }
}

public enum AccountDiscovery {
    /// Default root honors the CM_CLAUDE_ROOT test/E2E seam.
    public static func defaultRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["CM_CLAUDE_ROOT"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// A dir is an account iff named `.claude` or `.claude-<name>` and contains `.claude.json`.
    public static func discover(root: URL = defaultRoot()) -> [Account] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return entries
            .filter { url in
                let name = url.lastPathComponent
                guard name == ".claude" || name.hasPrefix(".claude-") else { return false }
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
                return fm.fileExists(atPath: url.appendingPathComponent(".claude.json").path)
            }
            .map(Account.init(configDir:))
            .sorted { a, b in
                if a.label == "main" { return true }
                if b.label == "main" { return false }
                return a.label < b.label
            }
    }
}
```

- [ ] **Step 1.4: Run** → PASS.
- [ ] **Step 1.5: Commit** — `git commit -m "feat: account model and .claude* discovery"`

---

### Task 2: Credentials parse / expiry / write-back JSON

**Files:** Create: `Sources/MonitorCore/Credentials.swift`, `Tests/MonitorCoreTests/CredentialsTests.swift`

- [ ] **Step 2.1: Write failing tests**

```swift
// ABOUTME: Tests credential JSON parsing, expiry logic with leeway, and
// ABOUTME: field-preserving token write-back JSON generation.
import XCTest
@testable import MonitorCore

final class CredentialsTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!)
    }

    func testParseValid() throws {
        let c = try Credentials.parse(fixture("credentials-valid"))
        XCTAssertEqual(c.accessToken, "sk-ant-oat01-FAKEFAKEFAKE")
        XCTAssertEqual(c.refreshToken, "sk-ant-ort01-FAKEFAKEFAKE")
        XCTAssertFalse(c.isExpired(now: Date()))
    }

    func testExpiredAndLeeway() throws {
        let c = try Credentials.parse(fixture("credentials-expired"))
        XCTAssertTrue(c.isExpired(now: Date()))
        // fresh token but within 5-minute leeway window counts as expired
        let edge = try Credentials.parse(fixture("credentials-valid"))
        XCTAssertTrue(edge.isExpired(now: edge.expiresAt.addingTimeInterval(-60)))
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try Credentials.parse(Data("{}".utf8)))
    }

    func testWriteBackPreservesUnknownFields() throws {
        let c = try Credentials.parse(fixture("credentials-valid"))
        let newExpiry = Date(timeIntervalSince1970: 2_000_000_000)
        let data = try c.updatedJSON(accessToken: "A2", refreshToken: "R2", expiresAt: newExpiry)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let oauth = obj["claudeAiOauth"] as! [String: Any]
        XCTAssertEqual(oauth["accessToken"] as? String, "A2")
        XCTAssertEqual(oauth["refreshToken"] as? String, "R2")
        XCTAssertEqual(oauth["expiresAt"] as? Int, 2_000_000_000_000)
        XCTAssertEqual(oauth["unknownField"] as? String, "must-survive-writeback")
        XCTAssertEqual((oauth["scopes"] as? [String])?.count, 2)
    }
}
```

- [ ] **Step 2.2: Run** `swift test --filter CredentialsTests` → FAIL.
- [ ] **Step 2.3: Implement `Credentials.swift`**

```swift
// ABOUTME: Models the Claude Code OAuth credential JSON stored in the Keychain and
// ABOUTME: preserves unknown fields so refreshed tokens can be written back safely.
import Foundation

public enum CredentialsError: Error { case malformed }

public struct Credentials: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let rawJSON: Data

    public static func parse(_ data: Data) throws -> Credentials {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String,
              let refresh = oauth["refreshToken"] as? String,
              let expiresMs = oauth["expiresAt"] as? Double
        else { throw CredentialsError.malformed }
        return Credentials(accessToken: access, refreshToken: refresh,
                           expiresAt: Date(timeIntervalSince1970: expiresMs / 1000),
                           rawJSON: data)
    }

    /// Leeway avoids using a token that dies mid-request.
    public func isExpired(now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        now >= expiresAt.addingTimeInterval(-leeway)
    }

    /// New credential JSON with rotated tokens; all fields not owned by us survive.
    public func updatedJSON(accessToken: String, refreshToken: String, expiresAt: Date) throws -> Data {
        guard var obj = try? JSONSerialization.jsonObject(with: rawJSON) as? [String: Any],
              var oauth = obj["claudeAiOauth"] as? [String: Any]
        else { throw CredentialsError.malformed }
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
        obj["claudeAiOauth"] = oauth
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }
}
```

- [ ] **Step 2.4: Run** → PASS. **Step 2.5: Commit** — `git commit -m "feat: credential parsing, expiry, write-back JSON"`

---

### Task 3: UsageSnapshot parsing

**Files:** Create: `Sources/MonitorCore/UsageSnapshot.swift`, `Tests/MonitorCoreTests/UsageSnapshotTests.swift`

- [ ] **Step 3.1: Write failing tests**

```swift
// ABOUTME: Tests lenient decoding of the OAuth usage endpoint response:
// ABOUTME: full plans, plans without per-model windows, and garbage input.
import XCTest
@testable import MonitorCore

final class UsageSnapshotTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!)
    }

    func testParseFull() throws {
        let s = try UsageSnapshot.parse(fixture("usage-full"))
        XCTAssertEqual(s.session?.utilization, 42.2)
        XCTAssertEqual(s.weekAll?.utilization, 18.0)
        XCTAssertEqual(s.weekSonnet?.utilization, 9.4)
        XCTAssertEqual(s.weekOpus?.utilization, 5.0)
        XCTAssertNotNil(s.session?.resetsAt)
    }

    func testParseWithoutSonnet() throws {
        let s = try UsageSnapshot.parse(fixture("usage-no-sonnet"))
        XCTAssertNil(s.weekSonnet)
        XCTAssertEqual(s.weekAll?.utilization, 18.0)
    }

    func testFractionalSecondsDate() throws {
        let json = #"{"five_hour":{"utilization":1.0,"resets_at":"2026-07-05T16:00:00.123Z"}}"#
        let s = try UsageSnapshot.parse(Data(json.utf8))
        XCTAssertNotNil(s.session?.resetsAt)
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try UsageSnapshot.parse(Data("[]".utf8)))
    }
}
```

- [ ] **Step 3.2: Run** → FAIL.
- [ ] **Step 3.3: Implement `UsageSnapshot.swift`** (key names centralized — the one place to fix if the Task 0 spike shows different keys):

```swift
// ABOUTME: Models the response of Anthropic's OAuth usage endpoint (the data behind
// ABOUTME: Claude Code's /usage screen) with lenient decoding for plan differences.
import Foundation

public enum UsageError: Error, Equatable { case malformed, unauthorized, http(Int) }

public struct WindowUsage: Equatable, Sendable {
    public let utilization: Double // 0–100
    public let resetsAt: Date?
    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    // Response keys — verified/adjusted from Task 0 spike capture.
    static let sessionKey = "five_hour"
    static let weekAllKey = "seven_day"
    static let weekSonnetKey = "seven_day_sonnet"
    static let weekOpusKey = "seven_day_opus"

    public let session: WindowUsage?
    public let weekAll: WindowUsage?
    public let weekSonnet: WindowUsage?
    public let weekOpus: WindowUsage?
    public let fetchedAt: Date

    public init(session: WindowUsage?, weekAll: WindowUsage?, weekSonnet: WindowUsage?,
                weekOpus: WindowUsage?, fetchedAt: Date) {
        self.session = session
        self.weekAll = weekAll
        self.weekSonnet = weekSonnet
        self.weekOpus = weekOpus
        self.fetchedAt = fetchedAt
    }

    public static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageError.malformed }
        func window(_ key: String) -> WindowUsage? {
            guard let w = obj[key] as? [String: Any],
                  let u = w["utilization"] as? Double else { return nil }
            return WindowUsage(utilization: u, resetsAt: (w["resets_at"] as? String).flatMap(parseISO))
        }
        return UsageSnapshot(session: window(sessionKey), weekAll: window(weekAllKey),
                             weekSonnet: window(weekSonnetKey), weekOpus: window(weekOpusKey),
                             fetchedAt: now)
    }

    static func parseISO(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s)
    }
}
```

- [ ] **Step 3.4: Run** → PASS. **Step 3.5: Commit** — `git commit -m "feat: usage snapshot parsing with lenient windows"`

---

### Task 4: BarFormatter

**Files:** Create: `Sources/MonitorCore/BarFormatter.swift`, `Tests/MonitorCoreTests/BarFormatterTests.swift`

- [ ] **Step 4.1: Write failing tests**

```swift
// ABOUTME: Tests the compact-triple bar formatting: rounding, separators,
// ABOUTME: missing windows, and warning/critical level thresholds.
import XCTest
@testable import MonitorCore

final class BarFormatterTests: XCTestCase {
    func snapshot(_ s: Double?, _ w: Double?, _ so: Double?) -> UsageSnapshot {
        UsageSnapshot(
            session: s.map { WindowUsage(utilization: $0, resetsAt: nil) },
            weekAll: w.map { WindowUsage(utilization: $0, resetsAt: nil) },
            weekSonnet: so.map { WindowUsage(utilization: $0, resetsAt: nil) },
            weekOpus: nil, fetchedAt: Date())
    }

    func testPlainTextTriple() {
        XCTAssertEqual(BarFormatter.plainText(for: snapshot(42.2, 18.0, 9.4)), "42·18·9")
    }

    func testMissingWindowsRenderDash() {
        XCTAssertEqual(BarFormatter.plainText(for: snapshot(42.2, 18.0, nil)), "42·18·–")
        XCTAssertEqual(BarFormatter.plainText(for: nil), "–·–·–")
    }

    func testLevels() {
        XCTAssertEqual(BarFormatter.level(for: 69.9), .normal)
        XCTAssertEqual(BarFormatter.level(for: 70.0), .warning)
        XCTAssertEqual(BarFormatter.level(for: 90.0), .critical)
        XCTAssertEqual(BarFormatter.level(for: nil), .missing)
    }

    func testSegmentsCarryLevels() {
        let segs = BarFormatter.segments(for: snapshot(95, 75, 5))
        XCTAssertEqual(segs.map(\.text), ["95", "·", "75", "·", "5"])
        XCTAssertEqual(segs[0].level, .critical)
        XCTAssertEqual(segs[2].level, .warning)
        XCTAssertEqual(segs[4].level, .normal)
    }
}
```

- [ ] **Step 4.2: Run** → FAIL.
- [ ] **Step 4.3: Implement `BarFormatter.swift`**

```swift
// ABOUTME: Turns a usage snapshot into the menu bar's compact "42·18·9" segments
// ABOUTME: with severity levels the UI maps to colors; pure logic, fully testable.
import Foundation

public enum UsageLevel: Equatable, Sendable { case normal, warning, critical, missing }

public struct BarSegment: Equatable, Sendable {
    public let text: String
    public let level: UsageLevel
    public init(text: String, level: UsageLevel) {
        self.text = text
        self.level = level
    }
}

public enum BarFormatter {
    public static func level(for utilization: Double?) -> UsageLevel {
        guard let u = utilization else { return .missing }
        if u >= 90 { return .critical }
        if u >= 70 { return .warning }
        return .normal
    }

    /// Fixed order: session · week(all) · week(sonnet). Absent window → "–".
    public static func segments(for snapshot: UsageSnapshot?) -> [BarSegment] {
        let windows = [snapshot?.session, snapshot?.weekAll, snapshot?.weekSonnet]
        var out: [BarSegment] = []
        for (i, w) in windows.enumerated() {
            if i > 0 { out.append(BarSegment(text: "·", level: .normal)) }
            if let u = w?.utilization {
                out.append(BarSegment(text: String(Int(u.rounded())), level: level(for: u)))
            } else {
                out.append(BarSegment(text: "–", level: .missing))
            }
        }
        return out
    }

    /// Plain-text form used by --print-once and tests, e.g. "42·18·9".
    public static func plainText(for snapshot: UsageSnapshot?) -> String {
        segments(for: snapshot).map(\.text).joined()
    }
}
```

- [ ] **Step 4.4: Run** → PASS. **Step 4.5: Commit** — `git commit -m "feat: bar formatter with color levels"`

---

### Task 5: KeychainStore (integration tests — real Keychain, own test items)

**Files:** Create: `Sources/MonitorCore/KeychainStore.swift`, `Tests/MonitorCoreTests/KeychainStoreTests.swift`

- [ ] **Step 5.1: Write failing integration tests** (items created/deleted by the test itself under a throwaway service name — same-process access, so no ACL prompts):

```swift
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
}
```

- [ ] **Step 5.2: Run** → FAIL.
- [ ] **Step 5.3: Implement `KeychainStore.swift`**

```swift
// ABOUTME: Reads and update-only-writes Claude Code credential items in the macOS
// ABOUTME: Keychain, resolving the per-CLAUDE_CONFIG_DIR service name per account.
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

    /// Candidate service names, tried in order. Pattern confirmed/adjusted by the
    /// Task 0 spike (`spike-results.md`). No cross-account fallback: a non-default
    /// dir must never resolve to the default entry, or accounts would show each
    /// other's data.
    func candidateServices(for account: Account) -> [String] {
        // Test/E2E seam: service name is simply "<prefix><label>".
        if let prefix = servicePrefixOverride { return [prefix + account.label] }
        let isDefault = account.configDir.lastPathComponent == ".claude"
        if isDefault { return ["Claude Code-credentials"] }
        return [
            "Claude Code-credentials-\(account.configDir.path)",
            "Claude Code-credentials-\(account.configDir.lastPathComponent)",
        ]
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
```

The tests above use dir `/tmp/.claude-kc` → label `kc` → test service `prefix + "kc"`, consistent with `addTestItem(service: prefix + "kc", …)`.

- [ ] **Step 5.4: Run** → PASS. **Step 5.5: Commit** — `git commit -m "feat: keychain credential store with update-only writes"`

---

### Task 6: UsageClient + TokenRefresher (mocked HTTP)

**Files:** Create: `Sources/MonitorCore/UsageClient.swift`, `Sources/MonitorCore/TokenRefresher.swift`, `Tests/MonitorCoreTests/MockURLProtocol.swift`, `Tests/MonitorCoreTests/HTTPClientTests.swift`

- [ ] **Step 6.1: Write `MockURLProtocol.swift`** (test infra, no test yet)

```swift
// ABOUTME: URLProtocol stub that lets tests intercept URLSession requests and
// ABOUTME: return canned responses, capturing the outgoing request for assertions.
import Foundation

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else { fatalError("handler unset") }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    static func respond(status: Int, json: String) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { req in
            (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
             Data(json.utf8))
        }
    }
}
```

- [ ] **Step 6.2: Write failing tests**

```swift
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
```

- [ ] **Step 6.3: Run** → FAIL.
- [ ] **Step 6.4: Implement `UsageClient.swift`**

```swift
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
```

- [ ] **Step 6.5: Implement `TokenRefresher.swift`**

```swift
// ABOUTME: Refreshes an expired Claude Code OAuth token pair (the same flow the
// ABOUTME: CLI uses) so the monitor can watch accounts that haven't run recently.
import Foundation

public enum RefreshError: Error, Equatable { case rejected, http(Int), malformed }

public struct TokenRefresher: Sendable {
    /// Claude Code's public OAuth client id (verify in Task 0 spike notes).
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let defaultURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    public struct Refreshed: Equatable, Sendable {
        public let accessToken: String
        public let refreshToken: String
        public let expiresAt: Date
    }

    let session: URLSession
    let tokenURL: URL

    public init(session: URLSession = .shared) {
        self.session = session
        let env = ProcessInfo.processInfo.environment["CM_TOKEN_URL"]
        self.tokenURL = env.flatMap(URL.init(string:)) ?? Self.defaultURL
    }

    public func refresh(refreshToken: String) async throws -> Refreshed {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ])
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 400 || code == 401 { throw RefreshError.rejected }
        guard (200..<300).contains(code) else { throw RefreshError.http(code) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String,
              let expiresIn = obj["expires_in"] as? Double
        else { throw RefreshError.malformed }
        return Refreshed(accessToken: access, refreshToken: refresh,
                         expiresAt: Date().addingTimeInterval(expiresIn))
    }
}
```

- [ ] **Step 6.6: Run** → PASS. **Step 6.7: Commit** — `git commit -m "feat: usage client and token refresher over mockable URLSession"`

---

### Task 7: Settings

**Files:** Create: `Sources/MonitorCore/Settings.swift`, `Tests/MonitorCoreTests/SettingsTests.swift`

- [ ] **Step 7.1: Write failing tests**

```swift
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
    }

    func testRoundTrip() {
        settings.selectedAccountId = "/Users/x/.claude-me"
        settings.pollIntervalSeconds = 120
        settings.hiddenAccountIds = ["/Users/x/.claude-backup"]
        XCTAssertEqual(settings.selectedAccountId, "/Users/x/.claude-me")
        XCTAssertEqual(settings.pollIntervalSeconds, 120)
        XCTAssertEqual(settings.hiddenAccountIds, ["/Users/x/.claude-backup"])
    }

    func testIntervalFloor() {
        settings.pollIntervalSeconds = 5
        XCTAssertEqual(settings.pollIntervalSeconds, 15) // floor protects the API
    }
}
```

- [ ] **Step 7.2: Run** → FAIL.
- [ ] **Step 7.3: Implement `Settings.swift`**

```swift
// ABOUTME: UserDefaults-backed app settings: selected account, poll interval,
// ABOUTME: hidden accounts. Explicit suite so `swift run` and the .app agree.
import Foundation

public final class Settings: @unchecked Sendable {
    public static let suiteName = "mn.tanasoft.claude-monitor"
    let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: Settings.suiteName)!) {
        self.defaults = defaults
    }

    public var selectedAccountId: String? {
        get { defaults.string(forKey: "selectedAccountId") }
        set { defaults.set(newValue, forKey: "selectedAccountId") }
    }

    public var pollIntervalSeconds: Int {
        get {
            let v = defaults.integer(forKey: "pollIntervalSeconds")
            return v == 0 ? 60 : max(15, v)
        }
        set { defaults.set(newValue, forKey: "pollIntervalSeconds") }
    }

    public var hiddenAccountIds: Set<String> {
        get { Set(defaults.stringArray(forKey: "hiddenAccountIds") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "hiddenAccountIds") }
    }
}
```

- [ ] **Step 7.4: Run** → PASS. **Step 7.5: Commit** — `git commit -m "feat: settings store"`

---

### Task 8: Poller engine

**Files:** Create: `Sources/MonitorCore/Poller.swift`, `Tests/MonitorCoreTests/FakeCredentialStore.swift`, `Tests/MonitorCoreTests/PollerTests.swift`

- [ ] **Step 8.1: Write `FakeCredentialStore.swift`**

```swift
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
```

- [ ] **Step 8.2: Write failing tests** (all `@MainActor`, async)

```swift
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

    func testNoCredentialsShowsNotLoggedIn() async {
        let poller = makePoller()
        await poller.pollAll()
        XCTAssertEqual(poller.states().first?.status, .notLoggedIn)
    }
}
```

- [ ] **Step 8.3: Run** → FAIL.
- [ ] **Step 8.4: Implement `Poller.swift`**

```swift
// ABOUTME: Polls usage for every discovered account, refreshing expired tokens
// ABOUTME: (single-flight, write-back) and publishing per-account states to the UI.
import Foundation

public enum AccountStatus: Equatable, Sendable {
    case pending                 // no fetch completed yet
    case ok(UsageSnapshot)
    case stale(UsageSnapshot)    // have old data; latest fetch failed
    case notLoggedIn             // no keychain credentials for this dir
    case reloginNeeded           // refresh rejected or 401 persists
}

public struct AccountState: Equatable, Sendable {
    public let account: Account
    public let status: AccountStatus
}

@MainActor
public final class Poller {
    let store: CredentialStore
    let usage: UsageClient
    let refresher: TokenRefresher
    let discover: () -> [Account]
    private var statuses: [String: AccountStatus] = [:]
    private var refreshing: Set<String> = []   // single-flight guard per account
    public var onUpdate: (([AccountState]) -> Void)?

    public init(store: CredentialStore, usage: UsageClient, refresher: TokenRefresher,
                discover: @escaping () -> [Account]) {
        self.store = store
        self.usage = usage
        self.refresher = refresher
        self.discover = discover
    }

    public func states() -> [AccountState] {
        discover().map { AccountState(account: $0, status: statuses[$0.id] ?? .pending) }
    }

    /// Sequential on purpose: 6 accounts, cheap endpoint — staggering for free.
    public func pollAll() async {
        for account in discover() { await poll(account) }
        onUpdate?(states())
    }

    func poll(_ account: Account) async {
        guard let creds = try? store.readCredentials(for: account) else {
            statuses[account.id] = .notLoggedIn
            return
        }
        var token = creds.accessToken
        if creds.isExpired() {
            guard let refreshed = await refreshAndPersist(account: account, creds: creds) else { return }
            token = refreshed
        }
        do {
            statuses[account.id] = .ok(try await usage.fetchUsage(accessToken: token))
        } catch UsageError.unauthorized {
            // Token looked fresh but the API disagrees — refresh once and retry.
            if let refreshed = await refreshAndPersist(account: account, creds: creds),
               let snap = try? await usage.fetchUsage(accessToken: refreshed) {
                statuses[account.id] = .ok(snap)
            } else if statuses[account.id] != .reloginNeeded {
                statuses[account.id] = .reloginNeeded
            }
        } catch {
            degradeToStale(account)
        }
    }

    /// Returns the new access token, or nil after setting the failure status.
    func refreshAndPersist(account: Account, creds: Credentials) async -> String? {
        guard !refreshing.contains(account.id) else { return nil }
        refreshing.insert(account.id)
        defer { refreshing.remove(account.id) }
        do {
            let r = try await refresher.refresh(refreshToken: creds.refreshToken)
            let json = try creds.updatedJSON(accessToken: r.accessToken,
                                             refreshToken: r.refreshToken,
                                             expiresAt: r.expiresAt)
            try store.writeCredentials(json, for: account)
            return r.accessToken
        } catch RefreshError.rejected {
            statuses[account.id] = .reloginNeeded
            return nil
        } catch {
            degradeToStale(account)
            return nil
        }
    }

    func degradeToStale(_ account: Account) {
        switch statuses[account.id] {
        case .ok(let snap), .stale(let snap): statuses[account.id] = .stale(snap)
        default: break // no data yet — stay pending/previous
        }
    }
}
```

- [ ] **Step 8.5: Run** `swift test` (full suite) → all PASS.
- [ ] **Step 8.6: Commit** — `git commit -m "feat: polling engine with refresh write-back and stale degradation"`

---

### Task 9: Executable — `--print-once` + status item UI

**Files:** Create: `Sources/ClaudeMonitor/main.swift`, `Sources/ClaudeMonitor/StatusItemController.swift`

- [ ] **Step 9.1: Implement `main.swift`**

```swift
// ABOUTME: Entry point: `--print-once` runs one headless poll and prints per-account
// ABOUTME: bar text (E2E seam); otherwise boots the menu bar app (no Dock icon).
import AppKit
import MonitorCore

func makePoller(settings: Settings) -> Poller {
    Poller(store: KeychainStore(), usage: UsageClient(), refresher: TokenRefresher(),
           discover: {
               AccountDiscovery.discover().filter { !settings.hiddenAccountIds.contains($0.id) }
           })
}

let settings = Settings()

if CommandLine.arguments.contains("--print-once") {
    Task { @MainActor in
        let poller = makePoller(settings: settings)
        await poller.pollAll()
        for state in poller.states() {
            let text: String
            switch state.status {
            case .ok(let s): text = BarFormatter.plainText(for: s)
            case .stale(let s): text = BarFormatter.plainText(for: s) + " (stale)"
            case .notLoggedIn: text = "not logged in"
            case .reloginNeeded: text = "re-login needed"
            case .pending: text = "pending"
            }
            print("\(state.account.label) \(text)")
        }
        exit(0)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusItemController(settings: settings, poller: makePoller(settings: settings))
controller.start()
app.run()
```

- [ ] **Step 9.2: Implement `StatusItemController.swift`**

```swift
// ABOUTME: Owns the NSStatusItem: renders the selected account's colored usage
// ABOUTME: numbers in the menu bar and builds the accounts dropdown menu.
import AppKit
import MonitorCore

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings: Settings
    private let poller: Poller
    private var states: [AccountState] = []
    private var timer: Timer?
    private var settingsWindow: NSWindow?

    init(settings: Settings, poller: Poller) {
        self.settings = settings
        self.poller = poller
        super.init()
    }

    func start() {
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude usage")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.menu = NSMenu()
        poller.onUpdate = { [weak self] states in
            self?.states = states
            self?.render()
            self?.rebuildMenu()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        schedule()
        pollNow()
    }

    @objc private func didWake() { pollNow() }

    private func pollNow() { Task { @MainActor in await poller.pollAll() } }

    private func schedule() {
        timer?.invalidate()
        let interval = TimeInterval(settings.pollIntervalSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollNow(); self?.schedule() } // re-read interval each tick
        }
    }

    private var selectedState: AccountState? {
        states.first { $0.account.id == settings.selectedAccountId } ?? states.first
    }

    // MARK: bar rendering

    private func color(for level: UsageLevel) -> NSColor {
        switch level {
        case .normal: return .labelColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        case .missing: return .secondaryLabelColor
        }
    }

    private func render() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let title = NSMutableAttributedString()
        guard let state = selectedState else {
            statusItem.button?.attributedTitle = NSAttributedString(string: "–", attributes: [.font: font])
            return
        }
        let (snapshot, dimAll): (UsageSnapshot?, Bool) = {
            switch state.status {
            case .ok(let s): return (s, false)
            case .stale(let s): return (s, true)
            case .pending, .notLoggedIn, .reloginNeeded: return (nil, true)
            }
        }()
        if case .reloginNeeded = state.status {
            title.append(NSAttributedString(string: "!", attributes: [.font: font, .foregroundColor: NSColor.systemRed]))
        } else {
            for seg in BarFormatter.segments(for: snapshot) {
                let c = dimAll ? NSColor.secondaryLabelColor : color(for: seg.level)
                title.append(NSAttributedString(string: seg.text, attributes: [.font: font, .foregroundColor: c]))
            }
        }
        statusItem.button?.attributedTitle = title
    }

    // MARK: menu

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        for state in states {
            let label = state.account.label.padding(toLength: 8, withPad: " ", startingAt: 0)
            let text: String
            switch state.status {
            case .ok(let s): text = BarFormatter.plainText(for: s)
            case .stale(let s): text = BarFormatter.plainText(for: s) + "  (stale)"
            case .pending: text = "…"
            case .notLoggedIn: text = "not logged in"
            case .reloginNeeded: text = "re-login needed → run claude-\(state.account.label)"
            }
            let item = NSMenuItem(title: "", action: #selector(selectAccount(_:)), keyEquivalent: "")
            item.attributedTitle = NSAttributedString(string: label + text, attributes: [.font: font])
            item.target = self
            item.representedObject = state.account.id
            item.state = state.account.id == selectedState?.account.id ? .on : .off
            if case .ok(let s) = state.status { item.toolTip = Self.detailText(for: s) }
            if case .stale(let s) = state.status { item.toolTip = Self.detailText(for: s) }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Tooltip rather than a submenu: menu items that own a submenu never fire
    /// their click action, which would break click-to-select on account rows.
    private static func detailText(for snapshot: UsageSnapshot) -> String {
        var lines: [String] = []
        func line(_ name: String, _ w: WindowUsage?) {
            guard let w else { return }
            var s = String(format: "%@ %.0f%%", name, w.utilization)
            if let r = w.resetsAt { s += " — resets \(resetFormatter.string(from: r))" }
            lines.append(s)
        }
        line("Session", snapshot.session)
        line("Week (all)", snapshot.weekAll)
        line("Week (Sonnet)", snapshot.weekSonnet)
        line("Week (Opus)", snapshot.weekOpus)
        return lines.joined(separator: "\n")
    }

    private static let resetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    // MARK: actions

    @objc private func selectAccount(_ sender: NSMenuItem) {
        settings.selectedAccountId = sender.representedObject as? String
        render()
        rebuildMenu()
    }

    @objc private func refreshNow() { pollNow() }

    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowFactory.make(settings: settings, onChange: { [weak self] in
            self?.schedule()
            self?.pollNow()
        }) }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 9.3: Temporary stub so it compiles before Task 10** — add to `StatusItemController.swift` bottom (replaced in Task 10 by the real file):

```swift
// Replaced by SettingsWindow.swift in the next task.
enum SettingsWindowFactory {
    @MainActor static func make(settings: Settings, onChange: @escaping () -> Void) -> NSWindow {
        NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 100),
                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
    }
}
```

- [ ] **Step 9.4: Verify build + headless mode** — `swift build` then `swift run ClaudeMonitor --print-once`. Expected: one line per real account, e.g. `main 12·55·31`, `backup not logged in` (numbers/statuses depend on live state; `not logged in` lines prove keychain resolution guards work). **First run may show macOS keychain prompts — click "Always Allow".** If accounts wrongly show `not logged in`, the spike's service naming didn't make it into `candidateServices` — fix there.
- [ ] **Step 9.5: Run the app** — `swift run ClaudeMonitor`, confirm: sparkle + `42·18·9`-style numbers in the bar, dropdown lists accounts with checkmark on selected, clicking another account switches the bar, Refresh Now works, Quit works.
- [ ] **Step 9.6: Commit** — `git commit -m "feat: menu bar app with account dropdown and print-once mode"`

---

### Task 10: Settings window + launch at login

**Files:** Create: `Sources/ClaudeMonitor/SettingsWindow.swift`; Modify: `Sources/ClaudeMonitor/StatusItemController.swift` (delete the stub `SettingsWindowFactory`)

- [ ] **Step 10.1: Implement `SettingsWindow.swift`**

```swift
// ABOUTME: SwiftUI settings window: poll interval, hidden accounts, launch at
// ABOUTME: login (only when running from the bundled .app), hosted in NSWindow.
import AppKit
import SwiftUI
import ServiceManagement
import MonitorCore

struct SettingsView: View {
    let settings: Settings
    let onChange: () -> Void
    @State private var interval: Int
    @State private var hidden: Set<String>
    @State private var launchAtLogin: Bool
    private let accounts = AccountDiscovery.discover()
    private let isBundled = Bundle.main.bundleIdentifier != nil

    init(settings: Settings, onChange: @escaping () -> Void) {
        self.settings = settings
        self.onChange = onChange
        _interval = State(initialValue: settings.pollIntervalSeconds)
        _hidden = State(initialValue: settings.hiddenAccountIds)
        _launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
    }

    var body: some View {
        Form {
            Picker("Refresh every", selection: $interval) {
                Text("30 s").tag(30)
                Text("1 min").tag(60)
                Text("2 min").tag(120)
                Text("5 min").tag(300)
            }
            .onChange(of: interval) { v in
                settings.pollIntervalSeconds = v
                onChange()
            }

            Section("Accounts shown") {
                ForEach(accounts) { account in
                    Toggle(account.label, isOn: Binding(
                        get: { !hidden.contains(account.id) },
                        set: { shown in
                            if shown { hidden.remove(account.id) } else { hidden.insert(account.id) }
                            settings.hiddenAccountIds = hidden
                            onChange()
                        }))
                }
            }

            Toggle("Launch at login", isOn: $launchAtLogin)
                .disabled(!isBundled)
                .onChange(of: launchAtLogin) { on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                }
            if !isBundled {
                Text("Launch at login needs the bundled app — run `make app`.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .padding(.bottom, 8)
    }
}

enum SettingsWindowFactory {
    @MainActor static func make(settings: Settings, onChange: @escaping () -> Void) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Claude Monitor Settings"
        window.contentView = NSHostingView(rootView: SettingsView(settings: settings, onChange: onChange))
        window.setContentSize(NSSize(width: 340, height: 380))
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
```

- [ ] **Step 10.2: Delete the `SettingsWindowFactory` stub from `StatusItemController.swift`.**
- [ ] **Step 10.3: Verify** — `swift build && swift test` all green; `swift run ClaudeMonitor`, open Settings…, change interval (watch polls speed up), hide `backup`/`backup2` (they vanish from dropdown), launch-at-login shows the bundled-app hint.
- [ ] **Step 10.4: Commit** — `git commit -m "feat: settings window with interval, hidden accounts, launch at login"`

---### Task 11: Bundling, E2E, Makefile, README

**Files:** Create: `scripts/make-app.sh`, `scripts/e2e.sh`, `Makefile`, `README.md`

- [ ] **Step 11.1: Write `scripts/make-app.sh`**

```bash
#!/usr/bin/env bash
# ABOUTME: Bundles the release binary into "Claude Monitor.app" (LSUIElement,
# ABOUTME: ad-hoc signed) so it can run without a Dock icon and launch at login.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="Claude Monitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ClaudeMonitor "$APP/Contents/MacOS/ClaudeMonitor"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ClaudeMonitor</string>
    <key>CFBundleIdentifier</key><string>mn.tanasoft.claude-monitor</string>
    <key>CFBundleName</key><string>Claude Monitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built: $APP  (install: cp -R into /Applications)"
```

- [ ] **Step 11.2: Write `scripts/e2e.sh`**

```bash
#!/usr/bin/env bash
# ABOUTME: End-to-end test: real binary + real keychain item + stub usage server;
# ABOUTME: asserts printed bar text for a fake account, then cleans everything up.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=8765
SERVICE_PREFIX="cm-e2e-$$-"
FAKEHOME=$(mktemp -d)
SERVER_PID=""

cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    security delete-generic-password -s "${SERVICE_PREFIX}e2e" >/dev/null 2>&1 || true
    rm -rf "$FAKEHOME"
}
trap cleanup EXIT

# fake account dir
mkdir -p "$FAKEHOME/.claude-e2e"
echo '{}' > "$FAKEHOME/.claude-e2e/.claude.json"

# keychain item with far-future expiry so no refresh is attempted
python3 - "$SERVICE_PREFIX" <<'PY'
import json, subprocess, sys
creds = {"claudeAiOauth": {"accessToken": "e2e-token", "refreshToken": "e2e-refresh",
                           "expiresAt": 4102444800000, "scopes": [], "subscriptionType": "max"}}
# -A: any app may read this throwaway fake-token item — avoids an ACL prompt
# for the freshly built test binary.
subprocess.run(["security", "add-generic-password", "-U", "-A",
                "-s", sys.argv[1] + "e2e", "-a", "e2e", "-w", json.dumps(creds)], check=True)
PY

# stub usage server
python3 - "$PORT" <<'PY' &
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"five_hour": {"utilization": 42.2, "resets_at": "2026-07-05T16:00:00Z"},
                           "seven_day": {"utilization": 18.0, "resets_at": "2026-07-08T00:00:00Z"},
                           "seven_day_sonnet": {"utilization": 9.4, "resets_at": "2026-07-08T00:00:00Z"}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
SERVER_PID=$!
sleep 1

swift build
OUT=$(CM_CLAUDE_ROOT="$FAKEHOME" \
      CM_KEYCHAIN_SERVICE_PREFIX="$SERVICE_PREFIX" \
      CM_USAGE_URL="http://127.0.0.1:$PORT/usage" \
      .build/debug/ClaudeMonitor --print-once)

echo "$OUT"
echo "$OUT" | grep -q "e2e 42·18·9" && echo "E2E PASS" || { echo "E2E FAIL"; exit 1; }
```

- [ ] **Step 11.3: Write `Makefile`**

```makefile
# ABOUTME: Developer entry points for building, testing, bundling, and running
# ABOUTME: the Claude Monitor menu bar app.
.PHONY: build test e2e app run

build:
    swift build

test:
    swift test

e2e:
    bash scripts/e2e.sh

app:
    bash scripts/make-app.sh

run:
    swift run ClaudeMonitor
```

- [ ] **Step 11.4: Run** `chmod +x scripts/*.sh && make test && make e2e` → unit/integration suites green, `E2E PASS`.
- [ ] **Step 11.5: Write `README.md`** — what it is, screenshot placeholder, `make app` install steps, first-run keychain "Always Allow" note (once per account), env seams table, troubleshooting (`not logged in` → run the account's alias once; `re-login needed` → `/login` in that account).
- [ ] **Step 11.6: Commit** — `git commit -m "feat: app bundling, e2e harness, make targets, readme"`

---

### Task 12: Live verification + guinea-pig refresh test

**Files:** none new (checklist; findings → `social.md` + issues)

- [ ] **Step 12.1: Cross-check numbers** — `swift run ClaudeMonitor --print-once`, then open `/usage` in 2–3 accounts (`claude`, `claude-me`, `claude-boldoo`) and compare percentages. Allow ±1 for rounding/timing.
- [ ] **Step 12.2: Guinea-pig refresh** — pick one low-stakes account (Mr. D chooses, e.g. `tergel`). Wait for (or find) its token expired, run `Refresh Now`, verify: monitor shows fresh numbers AND `claude-tergel` still opens logged-in (write-back preserved the rotated refresh token). If it got logged out: **stop trusting auto-refresh**, file issue, re-login, and flip strategy to read-only until fixed.
- [ ] **Step 12.3: Bundle + login item** — `make app`, `cp -R "Claude Monitor.app" /Applications/`, launch, enable Launch at Login, reboot-test at leisure.
- [ ] **Step 12.4: Final commit** — update `social.md`, `git commit -m "docs: live verification notes"`.

---

## Verification (end-to-end definition of done)

1. `make test` — unit + integration suites pass, output pristine.
2. `make e2e` — prints `E2E PASS` (real binary, real keychain item, stub API).
3. `swift run ClaudeMonitor --print-once` — live numbers matching `/usage` in the respective accounts.
4. Menu bar: colored compact triple for selected account; dropdown switches accounts; backups hideable; Settings interval takes effect; Quit/Refresh work.
5. Guinea-pig account survives an auto-refresh cycle with Claude Code still logged in.

## Risks / notes for the implementer

- **Unofficial API**: usage + token endpoints are what Claude Code itself uses, not public API. Lenient parsing + centralized key constants keep breakage a one-file fix.
- **Never commit `spike-raw/`** — it contains live tokens. Fixtures must be hand-sanitized.
- **Keychain naming is spike-determined** — `KeychainStore.candidateServices` has no cross-account fallback by design; wrong naming shows up as `not logged in`, never as wrong-account data.
- **Refresh rotation**: refresh tokens rotate on use. The write-back MUST persist the new refresh token (Task 8 test `testExpiredTokenRefreshesAndWritesBack` guards this). Race with a concurrently-refreshing Claude Code is possible but rare (we only refresh already-expired tokens); Task 12's guinea-pig test validates before trusting all accounts.
