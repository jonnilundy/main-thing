import AppKit

/// Borderless, non-activating panel that sits above the menu bar on every space.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Collapsed: the panel is mostly transparent and must not eat menu bar clicks.
        ignoresMouseEvents = true
        // Set last. `isFloatingPanel` and friends rewrite `level`, so nothing may follow this line.
        level = NotchPanel.level
    }

    /// One above the menu bar, so the notch covers the menu bar row.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit pushes windows below the menu bar. The notch must sit on the screen edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
