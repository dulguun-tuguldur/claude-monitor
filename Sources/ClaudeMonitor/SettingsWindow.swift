// ABOUTME: SwiftUI settings window: poll interval, hidden accounts, launch at
// ABOUTME: login (only when running from the bundled .app), hosted in NSWindow.
import AppKit
import SwiftUI
import ServiceManagement
import MonitorCore

struct SettingsView: View {
    let settings: MonitorCore.Settings
    let onChange: () -> Void
    @State private var interval: Int
    @State private var hidden: Set<String>
    @State private var launchAtLogin: Bool
    private let accounts = AccountDiscovery.discover()
    private let isBundled = Bundle.main.bundleIdentifier != nil

    init(settings: MonitorCore.Settings, onChange: @escaping () -> Void) {
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
    @MainActor static func make(settings: MonitorCore.Settings, onChange: @escaping () -> Void) -> NSWindow {
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
