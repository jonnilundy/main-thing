import CoreGraphics
import Foundation

/// Sizes of the open card. Pure math over measured title widths; the app measures with the same
/// fonts the rows draw with and hands the numbers in. The lanes themselves are in `Lanes`.
///
/// The band keeps task 1 where the collapsed notch had it, plus "1 of N" on the right. Rows 2..N
/// are 28pt pills below it, flush left in the same lanes. The card is as wide as its widest row,
/// at least 300pt, at most 440pt (or half the screen on a tiny one), and never narrower than the
/// band. A title wider than that stays on one line and truncates at the tail.
public enum OpenLayout {
    public static let minimumWidth: CGFloat = 300
    public static let maximumWidth: CGFloat = 440
    public static let screenWidthShare: CGFloat = 0.5
    /// Titles never wrap.
    public static let maxLines = 1
    /// A small line under the rows, like "sync failed: openbrain" or "API off on port N".
    public static let noteHeight: CGFloat = 14
    public static let noteSpacing: CGFloat = 6
    /// The "No tasks" line of an empty list.
    public static let emptyHeight: CGFloat = 18
    /// The card may take this share of the screen height before its rows scroll.
    public static let screenHeightShare: CGFloat = 0.6
    /// Room under the settled shape for the open bounce to overshoot into.
    public static let bounceHeadroom: CGFloat = 40
    /// The add card's slot at the very bottom, a row tall. Its card shows on hover.
    public static let addHeight: CGFloat = Lanes.rowHeight

    /// 440, or half the screen when that is less.
    public static func widthCap(screenWidth: CGFloat) -> CGFloat {
        min(maximumWidth, (screenWidth * screenWidthShare).rounded(.down))
    }

    /// Card content width, before the flares. The rows follow the widest title of rows 2..N,
    /// clamped; the band (task 1 plus the count) is never cut, so the card is at least that wide.
    public static func width(bandWidth: CGFloat, rowTitleWidths: [CGFloat], screenWidth: CGFloat) -> CGFloat {
        let widest = (rowTitleWidths.max() ?? 0) + Lanes.rowChrome
        let rows = min(max(ceil(widest), minimumWidth), widthCap(screenWidth: screenWidth))
        return max(rows, ceil(bandWidth))
    }

    /// The width a row title may use inside a card of `contentWidth`.
    public static func titleWidth(contentWidth: CGFloat) -> CGFloat {
        max(contentWidth - Lanes.rowChrome, 1)
    }

    /// Height of the body under the band: the top gap, one 28pt pill per row 2..N (or the
    /// "No tasks" line), any note lines, the add card's slot, and the bottom padding.
    public static func contentHeight(rows: Int, empty: Bool = false, notes: Int = 0) -> CGFloat {
        let body = empty ? emptyHeight : CGFloat(max(rows, 0)) * Lanes.rowHeight
        return Lanes.topGap + body + CGFloat(notes) * (noteSpacing + noteHeight) + addHeight + Lanes.bottomPadding
    }

    /// The panel height that fits the open card plus bounce headroom, capped at 60 percent of the
    /// screen, and the height the rows may take inside it before they scroll (nil: no scrolling).
    public static func panelHeight(notchHeight: CGFloat, contentHeight: CGFloat, screenHeight: CGFloat, minimum: CGFloat) -> (panel: CGFloat, rowsMax: CGFloat?) {
        let cap = (screenHeight * screenHeightShare).rounded(.down)
        let wanted = notchHeight + contentHeight + bounceHeadroom
        if wanted <= cap {
            return (max(ceil(wanted), minimum), nil)
        }
        // The rows block must fit in the cap with the gap above it, the add card and the padding
        // below, and the headroom.
        let rowsMax = cap - notchHeight - bounceHeadroom - Lanes.topGap - addHeight - Lanes.bottomPadding
        return (max(cap, minimum), max(rowsMax, 40))
    }
}

/// Rows that were clicked and are struck through, waiting to leave. Pure state; the app owns the
/// timers. A row leaves only when it is still pending when its timer fires, so a second click in
/// the meantime cancels the completion and nothing is sent anywhere.
public struct PendingCompletions: Equatable, Sendable {
    public private(set) var keys: [String] = []

    public init() {}

    public enum Toggle: Equatable, Sendable {
        /// The row is now struck through; start the timer.
        case armed
        /// The row was struck through and is restored.
        case cancelled
    }

    public func isPending(_ key: String) -> Bool { keys.contains(key) }

    /// A click on a row.
    public mutating func toggle(_ key: String) -> Toggle {
        if let i = keys.firstIndex(of: key) {
            keys.remove(at: i)
            return .cancelled
        }
        keys.append(key)
        return .armed
    }

    /// The timer fired. True when the row is still pending; it is removed from the pending set
    /// and the caller completes it. False when it was cancelled in the meantime.
    public mutating func finish(_ key: String) -> Bool {
        guard let i = keys.firstIndex(of: key) else { return false }
        keys.remove(at: i)
        return true
    }

    /// The list changed under us: forget rows that are gone.
    public mutating func keep(only present: Set<String>) {
        keys.removeAll { !present.contains($0) }
    }
}
