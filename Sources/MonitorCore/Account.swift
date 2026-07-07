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

    /// A dir is an account iff named `.claude` or `.claude-<name>` and has a `.claude.json`:
    /// inside the dir for aliased accounts, or the home-level sibling `~/.claude.json` for
    /// the default `.claude` account.
    public static func discover(root: URL = defaultRoot()) -> [Account] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return entries
            .filter { url in
                let name = url.lastPathComponent
                guard name == ".claude" || name.hasPrefix(".claude-") else { return false }
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
                // Aliased CLAUDE_CONFIG_DIR accounts keep .claude.json inside the dir.
                // The default account keeps it at the home-level sibling ~/.claude.json,
                // so accept that too for `.claude` — a fresh `claude` install has no
                // inner .claude.json.
                if fm.fileExists(atPath: url.appendingPathComponent(".claude.json").path) { return true }
                return name == ".claude" && fm.fileExists(atPath: root.appendingPathComponent(".claude.json").path)
            }
            .map(Account.init(configDir:))
            .sorted { a, b in
                if a.label == "main" { return true }
                if b.label == "main" { return false }
                return a.label < b.label
            }
    }
}
