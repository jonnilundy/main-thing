import CoreGraphics
import Foundation

/// Pure hover rules. The app feeds in the cursor and the visible shape, and acts on the intent.
public enum NotchHover {
    /// Extra reach around the open shape before it closes.
    public static let slack: CGFloat = 8
    /// Wait before opening, so a pass across the menu bar does not open the notch.
    public static let openDelay: Duration = .milliseconds(40)

    public enum Intent: Equatable, Sendable {
        case none
        case scheduleOpen
        case cancelOpen
        case close
    }

    /// Is the cursor on the visible shape? Collapsed: the shape itself. Open: the shape plus slack.
    public static func inside(_ point: CGPoint, shape: CGRect, isOpen: Bool, slack: CGFloat = slack) -> Bool {
        guard !shape.isEmpty else { return false }
        let reach = isOpen ? shape.insetBy(dx: -slack, dy: -slack) : shape
        return reach.contains(point)
    }

    /// What to do on a cursor move.
    public static func intent(isOpen: Bool, pendingOpen: Bool, inside: Bool) -> Intent {
        switch (isOpen, pendingOpen, inside) {
        case (true, _, true): .none
        case (true, _, false): .close
        case (false, false, true): .scheduleOpen
        case (false, true, false): .cancelOpen
        default: .none
        }
    }

    /// Screen point (AppKit, origin bottom left) to panel point (origin top left of the panel).
    public static func panelPoint(screenPoint: CGPoint, panelFrame: CGRect) -> CGPoint {
        CGPoint(x: screenPoint.x - panelFrame.minX, y: panelFrame.maxY - screenPoint.y)
    }
}
