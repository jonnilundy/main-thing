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

/// When a cursor move over the rows earns a haptic tick. Pure state; the app performs the tick.
/// One tick each time the cursor enters a row it was not on: moving within a row is silent, so is
/// a row that slides under a still cursor while the list animates (open, a cross off, a change).
public struct RowHaptics: Equatable, Sendable {
    /// After the list starts to move, entries are silent for this long.
    public static let settle: TimeInterval = 0.3

    /// The row the cursor is on, when it is on one.
    public private(set) var current: String?
    /// Entries before this time are the list moving under the cursor, not the cursor moving.
    public private(set) var quietUntil: TimeInterval = 0

    public init() {}

    /// The cursor is over `key`. True when that earns a tick.
    public mutating func enter(_ key: String, at now: TimeInterval) -> Bool {
        guard current != key else { return false }
        current = key
        return now >= quietUntil
    }

    /// The cursor left `key`. Coming back to it later is a new entry.
    public mutating func exit(_ key: String) {
        if current == key { current = nil }
    }

    /// The rows are about to move: the card opens, a row leaves, the list changes.
    public mutating func listAnimates(at now: TimeInterval) {
        quietUntil = now + RowHaptics.settle
    }
}
