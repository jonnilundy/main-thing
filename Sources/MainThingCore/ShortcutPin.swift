import Foundation

/// A card opened from a keyboard shortcut stays open with the pointer anywhere, until the pointer
/// has been on the card and left it. Pure state; `HoverController` ends the pin on the other ways
/// out (the shortcut again, Escape, the New task field closing).
public struct ShortcutPin: Equatable, Sendable {
    /// Show list: the card alone. Add task: the card with the New task field, so the pin also
    /// ends when that field closes.
    public enum Reason: Equatable, Sendable {
        case list
        case add
    }

    public var reason: Reason
    /// The pointer has been on the open card since the pin began.
    public private(set) var entered = false

    public init(_ reason: Reason) {
        self.reason = reason
    }

    /// A cursor move, with whether it is on the open card. False once the pin is over: the pointer
    /// was on the card and has now left it.
    public mutating func holds(inside: Bool) -> Bool {
        if inside {
            entered = true
            return true
        }
        return !entered
    }
}
