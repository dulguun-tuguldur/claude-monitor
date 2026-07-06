// ABOUTME: UserDefaults-backed app settings: selected account, poll interval,
// ABOUTME: hidden accounts. Explicit suite so `swift run` and the .app agree.
import Foundation

public final class Settings: @unchecked Sendable {
    public static let suiteName = "mn.tanasoft.claude-monitor.settings"
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
