import CoreGraphics
import Foundation

/// Sizes of the open card. Pure math over measured title widths and heights; the app measures
/// with the same fonts the rows draw with and hands the numbers in.
///
/// A row is `[padding 16][title ...][padding 16]`, flush left. The card is as wide as its widest
/// row, at least 300pt, at most 440pt (or half the screen on a tiny one). A title wider than that
/// stays on one line and truncates at the tail.
public enum OpenLayout {
    public static let minimumWidth: CGFloat = 300
    public static let maximumWidth: CGFloat = 440
    public static let screenWidthShare: CGFloat = 0.5
    /// One inset for the card content: left, right, bottom, and the gap under the notch row,
    /// all measured from the visible text edges. Picked against the 24pt bottom radius.
    public static let inset: CGFloat = 18
    public static var horizontalPadding: CGFloat { inset }
    /// Titles never wrap.
    public static let maxLines = 1
    public static let rowSpacing: CGFloat = 6
    /// The frame bottom sits at the descender, so the bottom padding is the inset itself.
    public static var bottomPadding: CGFloat { inset }

    /// The top padding that puts the first line's cap top `inset` below the notch row.
    /// `capTopOffset` is the title font's ascender minus its cap height: the leading above the caps.
    public static func topPadding(capTopOffset: CGFloat) -> CGFloat {
        max(inset - capTopOffset, 0)
    }
    /// A small line under the rows, like "sync failed: openbrain" or "API off on port N".
    public static let noteHeight: CGFloat = 14
    /// The card may take this share of the screen height before its rows scroll.
    public static let screenHeightShare: CGFloat = 0.6
    /// Room under the settled shape for the open bounce to overshoot into.
    public static let bounceHeadroom: CGFloat = 40

    /// Everything in a row that is not the title.
    public static var rowChrome: CGFloat { 2 * horizontalPadding }

    /// The other tasks are dimmed to 0.55, or 0.8 when the system asks for more contrast.
    public static func dimOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.8 : 0.55
    }

    /// 640, or half the screen when that is less.
    public static func widthCap(screenWidth: CGFloat) -> CGFloat {
        min(maximumWidth, (screenWidth * screenWidthShare).rounded(.down))
    }

    /// Card content width, before the flares, from the single line width of every title.
    public static func width(titleWidths: [CGFloat], screenWidth: CGFloat) -> CGFloat {
        let widest = (titleWidths.max() ?? 0) + rowChrome
        return min(max(ceil(widest), minimumWidth), widthCap(screenWidth: screenWidth))
    }

    /// The width a title may use inside a card of `contentWidth`.
    public static func titleWidth(contentWidth: CGFloat) -> CGFloat {
        max(contentWidth - rowChrome, 1)
    }

    /// Height of the rows block: rows, spacing, top and bottom padding, and any note lines.
    public static func contentHeight(rowHeights: [CGFloat], notes: Int = 0, topPadding: CGFloat) -> CGFloat {
        let rows = rowHeights.isEmpty ? [noteHeight + 4] : rowHeights
        let lines = rows.count + notes
        return topPadding + rows.reduce(0, +) + CGFloat(notes) * noteHeight
            + CGFloat(max(lines - 1, 0)) * rowSpacing + bottomPadding
    }

    /// The panel height that fits the open card plus bounce headroom, capped at 60 percent of the
    /// screen, and the height the rows may take inside it before they scroll (nil: no scrolling).
    public static func panelHeight(notchHeight: CGFloat, contentHeight: CGFloat, screenHeight: CGFloat, minimum: CGFloat) -> (panel: CGFloat, rowsMax: CGFloat?) {
        let cap = (screenHeight * screenHeightShare).rounded(.down)
        let wanted = notchHeight + contentHeight + bounceHeadroom
        if wanted <= cap {
            return (max(ceil(wanted), minimum), nil)
        }
        // The rows block must fit in the cap with its padding and the headroom. The top padding is
        // taken as 14, the title font's usual value; a point either way only shifts the scroll edge.
        let rowsMax = cap - notchHeight - bounceHeadroom - 14 - bottomPadding
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
