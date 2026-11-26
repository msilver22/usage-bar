import AppKit
import Combine
import SwiftUI
import UsageCore

@main
struct UsageBarMain {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--check-live") {
            var failed = false
            for provider in Provider.discover() {
                do {
                    for window in try await provider.fetch() {
                        print("\(provider.label) · \(window.id): \(window.reportedPercent.map { String($0) } ?? "unavailable")% used\(window.exceedsLimit ? " (over the limit)" : "")")
                    }
                } catch {
                    failed = true
                    print("\(provider.label): \(error.localizedDescription)")
                }
            }
            exit(failed ? 1 : 0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let updater = UpdateStore()
    private let panel = UsagePanel()
    private var statusItem: NSStatusItem!
    private var updateBadge: CALayer?
    private var updateSubscription: AnyCancellable?
    private var hotKey: GlobalShortcut!
    private var shortcut = ShortcutChoice(rawValue: UserDefaults.standard.string(forKey: "shortcut") ?? "") ?? .controlOptionU
    private var shortcutError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "UsageBar")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "UsageBar — Claude, Codex, and Antigravity usage"
            button.target = self
            button.action = #selector(togglePanel)
            button.setAccessibilityLabel("UsageBar")
            button.wantsLayer = true
            let dot = CALayer()
            dot.backgroundColor = NSColor.controlAccentColor.cgColor
            dot.cornerRadius = 3
            dot.isHidden = true
            button.layer?.addSublayer(dot)
            updateBadge = dot
        }
        panel.onClose = { [weak self] in
            self?.store.cancel()
            self?.statusItem.button?.highlight(false)
        }
        hotKey = GlobalShortcut { [weak self] in self?.togglePanel() }
        if !hotKey.register(shortcut) {
            shortcutError = "\(shortcut.rawValue) is unavailable. Choose another shortcut in Settings."
        }
        updater.isPanelOpen = { [weak self] in self?.panel.isOpen ?? false }
        updateSubscription = updater.$availableUpdate.sink { [weak self] update in
            self?.updateStatusBadge(hasUpdate: update != nil)
        }
        updater.startMonitoring()
        updateContent()
    }

    private func updateStatusBadge(hasUpdate: Bool) {
        guard let button = statusItem.button else { return }
        button.toolTip = hasUpdate
            ? "UsageBar — Update available on main"
            : "UsageBar — Claude, Codex, and Antigravity usage"
        updateBadge?.isHidden = !hasUpdate
        if hasUpdate {
            let y: CGFloat = button.isFlipped ? 3 : button.bounds.height - 9
            updateBadge?.frame = CGRect(x: max(button.bounds.width - 8, 12), y: y, width: 6, height: 6)
        }
    }

    private func updateContent() {
        let selection = Binding(get: { self.shortcut }, set: { choice in
            guard choice != self.shortcut else { return }
            if self.hotKey.register(choice) {
                self.shortcut = choice
                self.shortcutError = nil
                UserDefaults.standard.set(choice.rawValue, forKey: "shortcut")
            } else {
                self.shortcutError = "\(choice.rawValue) is already in use. Your previous shortcut is still active."
            }
            self.updateContent()
        })
        panel.setContent(PanelView(store: store, updater: updater, shortcut: selection, shortcutError: shortcutError))
    }

    @objc private func togglePanel() {
        if panel.isOpen { panel.close(); return }
        guard let button = statusItem.button, let window = button.window else { return }
        panel.show(below: window.convertToScreen(button.convert(button.bounds, to: nil)), on: window.screen)
        button.highlight(true)
        store.refresh()
        updater.checkIfStale()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.cancel()
        updater.stop()
    }
}
