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

    // Fresh default install: ~/.claude/ exists with NO inner .claude.json — the
    // default account's config file lives at the home-level sibling ~/.claude.json.
    func testDiscoversDefaultAccountViaHomeLevelClaudeJSON() throws {
        let freshRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: freshRoot) }
        let claudeDir = freshRoot.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        // sibling home-level config file, NOT inside ~/.claude/
        try Data("{}".utf8).write(to: freshRoot.appendingPathComponent(".claude.json"))

        let labels = AccountDiscovery.discover(root: freshRoot).map(\.label)
        XCTAssertEqual(labels, ["main"])
    }
}
