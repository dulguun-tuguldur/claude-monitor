// ABOUTME: Entry point: `--print-once` runs one headless poll and prints per-account
// ABOUTME: bar text (E2E seam); otherwise boots the menu bar app (no Dock icon).
import AppKit
import MonitorCore

@MainActor
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
// main.swift top-level code runs on the main thread but is not implicitly
// @MainActor-isolated by the compiler; assumeIsolated documents that fact
// so we can synchronously construct and start the MainActor-isolated controller.
let controller: StatusItemController = MainActor.assumeIsolated {
    let controller = StatusItemController(settings: settings, poller: makePoller(settings: settings))
    controller.start()
    return controller
}
app.run()
