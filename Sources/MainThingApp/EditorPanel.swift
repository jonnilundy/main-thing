import AppKit
import SwiftUI

/// The list editor's window: borderless, clear, floating, and able to become key so its fields
/// take typing. Non-activating, so the app in front stays in front and gets focus back on close.
final class EditorPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // The card's own drag moves it, so the handles and fields keep their mouse downs.
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        becomesKeyOnlyIfNeeded = false
        // Dark controls: a white caret and light placeholders on the black card.
        appearance = NSAppearance(named: .darkAqua)
        // Set last. `isFloatingPanel` rewrites `level`.
        isFloatingPanel = true
        level = .floating
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The frame is chosen and clamped by `EditorController`.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Takes the first click without waiting for the window to become key, and never sizes the
/// window from its content: the controller owns the frame.
final class EditorHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @available(*, unavailable)
    @objc required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("not used")
    }
}
