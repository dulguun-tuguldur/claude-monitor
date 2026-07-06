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
            guard let refreshed = await refreshAndPersist(account: account, creds: creds) else {
                // refreshAndPersist already set the correct status on failure — don't touch it.
                return
            }
            do {
                statuses[account.id] = .ok(try await usage.fetchUsage(accessToken: refreshed))
            } catch UsageError.unauthorized {
                // Still unauthorized with a freshly rotated token — genuinely needs relogin.
                statuses[account.id] = .reloginNeeded
            } catch {
                // Transient failure on the retry — the refresh itself succeeded, so degrade
                // rather than claiming relogin is needed.
                degradeToStale(account)
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
