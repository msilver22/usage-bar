import AppKit
import SwiftUI

/// Borderless panel pinned under the status item.
///
/// Replaces NSPopover, which repositions itself incorrectly (far below the menu bar, or pushed above it)
/// when its SwiftUI content changes height while shown — which every refresh does. Here the top edge
/// stays fixed under the icon and the panel only grows or shrinks downward.
@MainActor
final class UsagePanel: NSPanel {
    static let width: CGFloat = 380
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private var anchor: NSRect = .zero
    private var visibleFrame: NSRect?
    private var outsideClickMonitor: Any?
    private(set) var isOpen = false
    var onClose: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)
        contentView = background
    }

    override var canBecomeKey: Bool { true }

    func setContent(_ view: some View) {
        hosting.rootView = AnyView(view
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                self?.layout(height: height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
    }

    /// Shows the panel below `anchor`, a rect in screen coordinates.
    func show(below anchor: NSRect, on screen: NSScreen?) {
        self.anchor = anchor
        visibleFrame = (screen ?? NSScreen.main)?.visibleFrame
        layout(height: hosting.fittingSize.height)
        isOpen = true
        makeKeyAndOrderFront(nil)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    override func close() {
        guard isOpen else { return }
        isOpen = false
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        super.close()
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func resignKey() {
        super.resignKey()
        close()
    }

    private func layout(height: CGFloat) {
        guard height > 0, let visibleFrame else { return }
        let margin: CGFloat = 8
        let top = min(anchor.minY, visibleFrame.maxY) - 6
        let height = min(height, top - visibleFrame.minY - margin)
        let x = min(max(anchor.midX - Self.width / 2, visibleFrame.minX + margin), visibleFrame.maxX - Self.width - margin)
        setFrame(NSRect(x: x, y: top - height, width: Self.width, height: height), display: true)
        invalidateShadow()
    }
}
