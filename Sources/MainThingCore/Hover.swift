import CoreGraphics
import Foundation

/// Pure hover rules. The app feeds in the cursor and the visible shape, and acts on the intent.
public enum NotchHover {
    /// Extra reach around the open shape before it closes.
    public static let slack: CGFloat = 8

    public enum Intent: Equatable, Sendable {
        case none
        case open
        case close
    }

    /// Is the cursor on the visible shape? Collapsed: the shape itself. Open: the shape plus slack.
    public static func inside(_ point: CGPoint, shape: CGRect, isOpen: Bool, slack: CGFloat = slack) -> Bool {
        guard !shape.isEmpty else { return false }
        let reach = isOpen ? shape.insetBy(dx: -slack, dy: -slack) : shape
        return reach.contains(point)
    }

    /// What to do on a cursor move. No delay: the first move inside the shape opens.
    public static func intent(isOpen: Bool, inside: Bool) -> Intent {
        switch (isOpen, inside) {
        case (false, true): .open
        case (true, false): .close
        default: .none
        }
    }

    /// Screen point (AppKit, origin bottom left) to panel point (origin top left of the panel).
    public static func panelPoint(screenPoint: CGPoint, panelFrame: CGRect) -> CGPoint {
        CGPoint(x: screenPoint.x - panelFrame.minX, y: panelFrame.maxY - screenPoint.y)
    }
}
