import AppKit
import SwiftUI

/// Borderless, non-activating panel that hangs under the menu bar on every space.
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
        acceptsMouseMovedEvents = true
        // Collapsed: the panel is mostly transparent and must not eat menu bar clicks.
        // HoverController flips this from the hit test on every cursor move.
        ignoresMouseEvents = true
        // Set last. `isFloatingPanel` and friends rewrite `level`, so nothing may follow this line.
        level = NotchPanel.level
    }

    /// One above the menu bar level, so the notch stays over full screen apps. The frame never overlaps the menu bar.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)

    /// Key only while a field in the card takes typing: a rename or a new task. Non-activating,
    /// so the app in front stays in front.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// AppKit may nudge frames near the menu bar. The frame is exact by construction.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosting view that takes the first click without activating the app, and reports
/// cursor moves over itself. The panel is never key, so AppKit would not send it
/// mouseMoved events on its own; the tracking area with `.activeAlways` does.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// Called with the cursor position in AppKit screen coordinates.
    var onMouseMove: ((CGPoint) -> Void)?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    private func report(_ event: NSEvent) {
        onMouseMove?(HoverController.screenPoint(of: event))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        report(event)
    }

    // Enter and exit events are also synthesized when tracking areas change, for example
    // when the open content appears, and then their locationInWindow is garbage (points on
    // the window's top edge with a random x). Only the real cursor position is trusted here.
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onMouseMove?(NSEvent.mouseLocation)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseMove?(NSEvent.mouseLocation)
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        // The panel's frame is set by hand (`PanelLayout`). Without this the hosting view measures
        // its minimum and maximum size again on every layout pass, so on every hover frame.
        sizingOptions = []
    }

    @available(*, unavailable)
    @objc required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("not used")
    }
}
