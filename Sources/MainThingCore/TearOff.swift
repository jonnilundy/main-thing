import CoreGraphics
import Foundation

/// Tearing the list editor off the open card: press anywhere on the card and drag down. Pure
/// rules; the app feeds in cursor positions (panel coordinates, y growing down) and acts on the
/// phase. A move under `clickSlop` is still a click. Past it, the card stretches with rubber band
/// resistance, up to `maxStretch` past its bottom edge; at that point the editor tears off.
public enum TearOff {
    /// Moves shorter than this are clicks, so row clicks and cross offs keep working.
    public static let clickSlop: CGFloat = 6
    /// The card stretches this far past its bottom edge before the editor tears off.
    public static let maxStretch: CGFloat = 24
    /// The rubber band's dimension: stretch = d t / (t + d). Slope 1 at the start, then harder.
    public static let bandDimension: CGFloat = 60
    /// Keep a grab point at least this far inside the editor's edges.
    public static let grabMargin: CGFloat = 12

    /// The card's stretch for `travel` points of downward cursor travel.
    public static func stretch(travel: CGFloat) -> CGFloat {
        let t = max(travel, 0)
        return bandDimension * t / (t + bandDimension)
    }

    /// Downward travel at which the stretch reaches `maxStretch`: 40pt.
    public static var threshold: CGFloat {
        maxStretch * bandDimension / (bandDimension - maxStretch)
    }

    /// The cursor's offset from the card's top left at the press, kept inside a window of `size`.
    public static func grab(_ offset: CGPoint, in size: CGSize) -> CGPoint {
        func clamp(_ v: CGFloat, _ length: CGFloat) -> CGFloat {
            let low = min(grabMargin, length / 2)
            return min(max(v, low), max(length - grabMargin, low))
        }
        return CGPoint(x: clamp(offset.x, size.width), y: clamp(offset.y, size.height))
    }
}

/// One press on the open card, from mouse down to mouse up.
public struct TearOffDrag: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Still within the click slop.
        case press
        /// Past the slop: the card stretches (not under Reduce Motion) and the release is no click.
        case stretch
        /// Past the threshold: the editor is out and follows the cursor.
        case torn
    }

    public enum Release: Equatable, Sendable {
        /// Let the click through: a row click or a cross off.
        case click
        /// Not far enough: the card springs back.
        case springBack
        /// The torn off editor stays where it is.
        case drop
        /// Reduce Motion: no stretch and no tracking; the editor appears at the release.
        case appear
    }

    public let start: CGPoint
    public let reduceMotion: Bool
    public private(set) var phase: Phase = .press
    /// Downward cursor travel since the press, never negative.
    public private(set) var travel: CGFloat = 0

    public init(start: CGPoint, reduceMotion: Bool) {
        self.start = start
        self.reduceMotion = reduceMotion
    }

    /// The card's stretch now: nothing before the slop, after the tear, or under Reduce Motion.
    public var stretch: CGFloat {
        phase == .stretch && !reduceMotion ? TearOff.stretch(travel: travel) : 0
    }

    /// Past the slop at some point: the release must not click. Sticky.
    public var moved: Bool { phase != .press }

    @discardableResult
    public mutating func move(to point: CGPoint) -> Phase {
        travel = max(point.y - start.y, 0)
        if phase == .press, hypot(point.x - start.x, point.y - start.y) >= TearOff.clickSlop {
            phase = .stretch
        }
        if phase == .stretch, !reduceMotion, travel >= TearOff.threshold {
            phase = .torn
        }
        return phase
    }

    public func release() -> Release {
        switch phase {
        case .press: return .click
        case .torn: return .drop
        case .stretch: return reduceMotion && travel >= TearOff.threshold ? .appear : .springBack
        }
    }
}
