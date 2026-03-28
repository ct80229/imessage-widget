import AppKit
import SwiftUI

/// NSPanel that hosts the widget UI. Behaves like a normal window — no always-on-top.
class WidgetPanel: NSPanel {

    private static let defaultWidth:   CGFloat = 290
    private static let defaultHeight:  CGFloat = 600
    private static let rightInset:     CGFloat = 20
    private static let extraTopGap:    CGFloat = 8
    private static let extraBottomGap: CGFloat = 10

    private var hostingView: NSHostingView<WidgetRootView>!

    init(store: ConversationStore) {
        let frame = Self.defaultFrame()
        super.init(
            contentRect: frame,
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing:     .buffered,
            defer:       false
        )

        // Window behavior
        self.level                       = .normal
        self.collectionBehavior          = [.managed, .participatesInCycle]
        self.backgroundColor             = .clear
        self.isOpaque                    = false
        self.hasShadow                   = true
        self.hidesOnDeactivate           = false
        self.isMovableByWindowBackground = true
        self.isReleasedWhenClosed        = false
        self.titleVisibility             = .hidden
        self.titlebarAppearsTransparent  = true

        // Size constraints
        self.minSize = NSSize(width: 200, height: 150)
        self.maxSize = NSSize(width: 800, height: 2000)

        // Auto-save frame (position + size) under this name.
        // AppKit persists to UserDefaults automatically.
        self.setFrameAutosaveName("iMessageWidgetPanel")

        // SwiftUI content
        let rootView = WidgetRootView(store: store)
        hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = frame
        hostingView.autoresizingMask = [.width, .height]
        contentView = hostingView

        // Listen for screen configuration changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func show() {
        // If this is the first launch (no autosaved frame), position at default.
        if !self.setFrameUsingName(self.frameAutosaveName) {
            self.setFrame(Self.defaultFrame(), display: true)
        }
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    @objc private func screenDidChange() {
        // Clamp the window to the new visible area if it overflows.
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        var f = self.frame

        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width }
        if f.origin.x < visible.minX { f.origin.x = visible.minX }
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height }
        if f.origin.y < visible.minY { f.origin.y = visible.minY }
        f.size.width  = min(f.size.width, visible.width)
        f.size.height = min(f.size.height, visible.height)

        self.setFrame(f, display: true)
    }

    /// Default frame for a fresh launch (right side, full height).
    private static func defaultFrame() -> CGRect {
        guard let screen = NSScreen.main else {
            return CGRect(x: 0, y: 0, width: defaultWidth, height: defaultHeight)
        }
        let visible = screen.visibleFrame
        let h = visible.height - extraTopGap - extraBottomGap
        let x = screen.frame.maxX - defaultWidth - rightInset
        let y = visible.minY + extraBottomGap
        return CGRect(x: x, y: y, width: defaultWidth, height: h)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
