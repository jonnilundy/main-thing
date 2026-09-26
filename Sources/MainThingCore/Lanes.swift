import CoreGraphics
import Foundation

/// The two lanes of the card, in every state: one for markers, one for text.
///
/// The band (the notch row) is `[padding 18][marker slot 18][gap 10][title ...][trailing 24]`, with
/// the count "1 of N" right aligned inside the padding when open. A row is
/// `[pill inset 8][pill padding 10][marker slot 18][gap 10][title ...][pill trailing 16][pill inset 8]`.
/// Open, the band gets a pill too, with the same inset, behind its dot, title and count.
/// The slot starts 18 from the body edge either way, so the pink dot and the row numbers share
/// one lane and every title starts at 46. Points at 1x, white opacities as fractions.
public enum Lanes {
    public static let padding: CGFloat = 18
    public static let markerSlot: CGFloat = 18
    public static let gap: CGFloat = 10
    public static let pillInset: CGFloat = 8
    public static let pillPadding: CGFloat = 10
    /// Right of the text, in the band and in a row: as far in as the dot and the row numbers sit
    /// on the left (the slot start plus half the slot around the 7pt dot), so both sides read even.
    public static let trailingPadding: CGFloat = 24
    /// A row pill's padding right of its title, so the title ends `trailingPadding` from the edge.
    public static var pillTrailingPadding: CGFloat { trailingPadding - pillInset }
    public static let pillRadius: CGFloat = 8
    public static let rowHeight: CGFloat = 28
    /// Gap between the band and the first pill.
    public static let topGap: CGFloat = 6
    /// The last pill sits this far above the rounded bottom.
    public static let bottomPadding: CGFloat = 10
    /// Between the title and the count in the band.
    public static let countGap: CGFloat = 12
    /// The collapsed notch never grows past this content width.
    public static let maximumCollapsedWidth: CGFloat = 600

    /// Where the marker slot starts, from the body edge. The same in the band and in a row.
    public static var slotStart: CGFloat { padding }
    public static var rowSlotStart: CGFloat { pillInset + pillPadding }
    /// Where every title starts, from the body edge. The same in the band and in a row.
    public static var textStart: CGFloat { slotStart + markerSlot + gap }
    public static var rowTextStart: CGFloat { rowSlotStart + markerSlot + gap }
    /// Everything in the collapsed band that is not the title.
    public static var collapsedChrome: CGFloat { textStart + trailingPadding }
    /// Everything in a row that is not the title.
    public static var rowChrome: CGFloat { rowTextStart + pillTrailingPadding + pillInset }
    /// The widest title the collapsed band can show without truncating.
    public static var collapsedTitleWidth: CGFloat { maximumCollapsedWidth - collapsedChrome }

    /// Collapsed content width before the flares: dot, title and padding, clamped to
    /// `minimum` (the plain 169 or the camera housing) and `maximumCollapsedWidth`.
    public static func collapsedWidth(titleWidth: CGFloat?, minimum: CGFloat) -> CGFloat {
        guard let titleWidth, titleWidth > 0 else { return minimum }
        return min(max(ceil(titleWidth) + collapsedChrome, minimum), maximumCollapsedWidth)
    }

    public static func countText(_ count: Int) -> String { "1 of \(count)" }

    /// The band when open: the collapsed band plus the count on the right.
    public static func bandWidth(collapsedWidth: CGFloat, countWidth: CGFloat) -> CGFloat {
        collapsedWidth + countGap + ceil(countWidth)
    }

    /// The title lane in the open band, next to the count.
    public static func bandTitleWidth(contentWidth: CGFloat, countWidth: CGFloat) -> CGFloat {
        max(contentWidth - textStart - countGap - ceil(countWidth) - trailingPadding, 1)
    }

    public static func pillWidth(contentWidth: CGFloat) -> CGFloat {
        max(contentWidth - 2 * pillInset, 1)
    }

    /// Task 1's pill in the open band, in band coordinates (origin top left): the same inset and
    /// radius as a row pill, a row tall where the band has room, centered in the band. The dot,
    /// the title and the count stay where the band puts them; the pill only sits behind them.
    /// It is task 1's hover and click target, so the cursor needs to be on the row, not the letters.
    public static func bandPill(width: CGFloat, height: CGFloat) -> CGRect {
        let pillHeight = min(rowHeight, max(height, 0))
        return CGRect(x: pillInset, y: (height - pillHeight) / 2, width: pillWidth(contentWidth: width), height: pillHeight)
    }

    /// Sub tasks are dim so the main thing stays the focus; the hovered row lifts.
    public static func rowTitleOpacity(hovered: Bool, increaseContrast: Bool) -> Double {
        hovered ? 0.9 : (increaseContrast ? 0.8 : 0.46)
    }

    public static func numberOpacity(hovered: Bool, increaseContrast: Bool) -> Double {
        hovered ? 0.5 : (increaseContrast ? 0.6 : 0.24)
    }

    public static let countOpacity: Double = 0.42
    public static let pillOpacity: Double = 0.08

    /// The rows fade in one after another on open: 20ms per row, at most 120ms.
    public static func rowDelay(index: Int) -> Double {
        min(0.02 * Double(max(index, 0)), 0.12)
    }
}
