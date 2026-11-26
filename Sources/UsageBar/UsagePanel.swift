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
    private var contentHeight: CGFloat = 0
    private var outsideClickMonitor: Any?
    private var screenObserver: NSObjectProtocol?
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
        hosting.rootView = AnyView(
            ScrollView(.vertical) {
                view
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                        self?.contentHeight = height
                        if self?.isOpen == true { self?.layout() }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
    }

    /// Shows the panel below `anchor`, a rect in screen coordinates.
    func show(below anchor: NSRect, on screen: NSScreen?) {
        self.anchor = anchor
        let targetScreen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
            ?? screen
            ?? NSScreen.main
        visibleFrame = targetScreen?.visibleFrame
        layout()
        isOpen = true
        makeKeyAndOrderFront(nil)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    override func close() {
        guard isOpen else { return }
        isOpen = false
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        super.close()
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func resignKey() {
        super.resignKey()
        close()
    }

    private func layout() {
        // NSHostingView.fittingSize is 0 when sizingOptions is empty, so use the measured SwiftUI height.
        let targetHeight = contentHeight > 0 ? contentHeight : frame.height
        guard targetHeight > 0, let visibleFrame else { return }
        let margin: CGFloat = 8
        let top = min(anchor.minY, visibleFrame.maxY) - 6
        let height = min(targetHeight, max(top - visibleFrame.minY - margin, 0))
        guard height > 0 else { return }
        let x = min(max(anchor.midX - Self.width / 2, visibleFrame.minX + margin), visibleFrame.maxX - Self.width - margin)
        setFrame(NSRect(x: x, y: top - height, width: Self.width, height: height), display: true)
        invalidateShadow()
    }
}
