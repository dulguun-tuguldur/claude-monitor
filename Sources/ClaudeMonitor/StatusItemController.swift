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

// Replaced by SettingsWindow.swift in the next task.
enum SettingsWindowFactory {
    @MainActor static func make(settings: Settings, onChange: @escaping () -> Void) -> NSWindow {
        NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 100),
                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
    }
}
