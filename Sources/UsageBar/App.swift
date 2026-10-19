import AppKit
import SwiftUI
import UsageCore

@main
struct UsageBarMain {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--check-live") {
            var failed = false
            for service in Service.allCases {
                do {
                    let windows = try await (service == .claude ? ClaudeUsage.fetch() : CodexUsage.fetch())
                    for window in windows {
                        print("\(service.rawValue) · \(window.id): \(window.usedPercent.map { String($0) } ?? "unavailable")% used")
                    }
                } catch {
                    failed = true
                    print("\(service.rawValue): \(error.localizedDescription)")
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = UsageStore()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem!
    private var hotKey: GlobalShortcut!
    private var shortcut = ShortcutChoice(rawValue: UserDefaults.standard.string(forKey: "shortcut") ?? "") ?? .controlOptionU
    private var shortcutError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "UsageBar")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "UsageBar — Claude and Codex usage"
            button.target = self
            button.action = #selector(togglePanel)
            button.setAccessibilityLabel("UsageBar")
        }
        popover.behavior = .transient
        popover.delegate = self
        hotKey = GlobalShortcut { [weak self] in self?.togglePanel() }
        if !hotKey.register(shortcut) {
            shortcutError = "\(shortcut.rawValue) is unavailable. Choose another shortcut in Settings."
        }
        updateContent()
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
        popover.contentViewController = NSHostingController(rootView: PanelView(store: store, shortcut: selection, shortcutError: shortcutError))
    }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        store.refresh()
    }

    func popoverDidClose(_ notification: Notification) { store.cancel() }
    func applicationWillTerminate(_ notification: Notification) { store.cancel() }
}
