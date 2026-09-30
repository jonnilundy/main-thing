import CoreGraphics
import Foundation

/// One step of an outline, y down. Plain data, so checks can walk the outline the view draws.
public enum OutlineSegment: Equatable, Sendable {
    case move(CGPoint)
    case line(CGPoint)
    case quad(to: CGPoint, control: CGPoint)
    /// The short way around `center`, from angle `from` to angle `to`, in degrees, y down (90 is
    /// straight down). At most a quarter turn.
    case arc(center: CGPoint, radius: CGFloat, from: Double, to: Double)
    case close
}

/// The outline under a hardware notch: the bridge in the menu bar row and the card below it, one
/// closed path, so the camera notch and the card read as one black shape.
///
/// The bridge is exactly the camera notch's width, from the screen top to the card's top edge (the
/// menu bar's bottom edge). The narrowest card is as wide as the notch, and its sides continue the
/// notch's sides straight down. A wider card flares out from the notch's width to its own below the
/// menu bar: a concave flare off the bridge's side (the same flare as the plain notch's, a quarter
/// curve with its control on the corner), a short ledge, and a rounded shoulder into the card's
/// side. The ledge sits `joinDrop` under the menu bar, so the title keeps its room above; the
/// flare and the shoulder are `joinRadius` wide, or half the step each while the step is smaller,
/// so the join grows smoothly out of a straight side as the card widens.
///
/// Open, the bridge spreads to the card's full width (`openness` 1): the shape's top edge is the
/// screen top across the whole card, with the plain notch's concave flare at both top corners, so
/// the card fills the menu bar row above it and the camera sits inside its black. At 0 it is the
/// camera-wide bridge; in between the bridge widens and the flares grow, one smooth morph.
public enum NotchOutline {
    /// Width of the concave flare and of the rounded shoulder at their full size.
    public static let joinRadius: CGFloat = NotchGeometry.flare
    /// How far under the menu bar the ledge between the flare and the shoulder sits, at full size.
    public static let joinDrop: CGFloat = 4

    /// The join on one side for a card side `step` out from the bridge's side: the flare's width,
    /// the drop under the menu bar, and the shoulder's radius. All 0 for a step of 0 or less.
    public static func join(step: CGFloat) -> (flare: CGFloat, drop: CGFloat, shoulder: CGFloat) {
        guard step > 0 else { return (0, 0, 0) }
        let flare = min(joinRadius, step / 2)
        return (flare, joinDrop * flare / joinRadius, flare)
    }

    /// The outline in `rect`, the card's frame with the flare padding on both sides, y down.
    /// `rect.minY` is the card's top edge. The bridge rises `bridgeHeight` above it, `bridgeWidth`
    /// wide, its center `bridgeOffset` from `rect.midX`. The card's sides are `padding` in from
    /// the rect, as the plain notch's; `bottomRadius` rounds its bottom corners. `openness` (0 to 1)
    /// spreads the bridge to the card's width and grows the flares at its top corners.
    public static func bridged(
        in rect: CGRect, padding: CGFloat = NotchGeometry.flare, bottomRadius: CGFloat,
        bridgeWidth: CGFloat, bridgeHeight: CGFloat, bridgeOffset: CGFloat = 0, openness: CGFloat = 0
    ) -> [OutlineSegment] {
        let top = rect.minY
        let bottom = max(rect.maxY, top)
        let left = rect.minX + padding
        let right = max(rect.maxX - padding, left)
        let spread = min(max(openness, 0), 1)
        let camera = min(bridgeWidth, right - left)
        let width = camera + (right - left - camera) * spread
        let bridgeLeft = rect.midX + bridgeOffset * (1 - spread) - width / 2
        let bridgeRight = bridgeLeft + width
        let bridgeTop = top - bridgeHeight
        // The concave flare at the top corners, outside the bridge's sides.
        let flare = min(padding * spread, bridgeHeight)

        var leftJoin = join(step: bridgeLeft - left)
        var rightJoin = join(step: right - bridgeRight)
        // A card too short for the joins (while it grows out of an empty notch) gets smaller joins.
        let height = bottom - top
        let tallest = max(leftJoin.drop + leftJoin.shoulder, rightJoin.drop + rightJoin.shoulder)
        if tallest > height {
            let scale = tallest > 0 ? height / tallest : 0
            leftJoin = (leftJoin.flare * scale, leftJoin.drop * scale, leftJoin.shoulder * scale)
            rightJoin = (rightJoin.flare * scale, rightJoin.drop * scale, rightJoin.shoulder * scale)
        }
        let sideTop = max(leftJoin.drop + leftJoin.shoulder, rightJoin.drop + rightJoin.shoulder)
        let b = max(min(bottomRadius, (right - left) / 2, height - sideTop), 0)

        var path: [OutlineSegment] = [
            .move(CGPoint(x: bridgeLeft - flare, y: bridgeTop)),
            .line(CGPoint(x: bridgeRight + flare, y: bridgeTop)),
        ]
        if flare > 0 {
            path.append(.quad(to: CGPoint(x: bridgeRight, y: bridgeTop + flare), control: CGPoint(x: bridgeRight, y: bridgeTop)))
        }
        path.append(.line(CGPoint(x: bridgeRight, y: top)))
        // Right join, from the bridge's side out to the card's.
        if rightJoin.flare > 0 {
            let ledge = top + rightJoin.drop
            path.append(.quad(to: CGPoint(x: bridgeRight + rightJoin.flare, y: ledge), control: CGPoint(x: bridgeRight, y: ledge)))
            path.append(.line(CGPoint(x: right - rightJoin.shoulder, y: ledge)))
            path.append(.quad(to: CGPoint(x: right, y: ledge + rightJoin.shoulder), control: CGPoint(x: right, y: ledge)))
        } else if right != bridgeRight {
            path.append(.line(CGPoint(x: right, y: top)))
        }
        path.append(.line(CGPoint(x: right, y: bottom - b)))
        path.append(.arc(center: CGPoint(x: right - b, y: bottom - b), radius: b, from: 0, to: 90))
        path.append(.line(CGPoint(x: left + b, y: bottom)))
        path.append(.arc(center: CGPoint(x: left + b, y: bottom - b), radius: b, from: 90, to: 180))
        // Left join, from the card's side in to the bridge's.
        if leftJoin.flare > 0 {
            let ledge = top + leftJoin.drop
            path.append(.line(CGPoint(x: left, y: ledge + leftJoin.shoulder)))
            path.append(.quad(to: CGPoint(x: left + leftJoin.shoulder, y: ledge), control: CGPoint(x: left, y: ledge)))
            path.append(.line(CGPoint(x: bridgeLeft - leftJoin.flare, y: ledge)))
            path.append(.quad(to: CGPoint(x: bridgeLeft, y: top), control: CGPoint(x: bridgeLeft, y: ledge)))
        } else {
            path.append(.line(CGPoint(x: left, y: top)))
            if left != bridgeLeft { path.append(.line(CGPoint(x: bridgeLeft, y: top))) }
        }
        if flare > 0 {
            path.append(.line(CGPoint(x: bridgeLeft, y: bridgeTop + flare)))
            path.append(.quad(to: CGPoint(x: bridgeLeft - flare, y: bridgeTop), control: CGPoint(x: bridgeLeft, y: bridgeTop)))
        }
        path.append(.close)
        return path
    }

    /// Points along an outline, curves sampled `steps` times each: for checks.
    public static func samples(_ outline: [OutlineSegment], steps: Int = 16) -> [CGPoint] {
        var points: [CGPoint] = []
        var current = CGPoint.zero
        var start = CGPoint.zero
        for segment in outline {
            switch segment {
            case .move(let p):
                current = p; start = p; points.append(p)
            case .line(let p):
                current = p; points.append(p)
            case .quad(let to, let control):
                for i in 1...steps {
                    let t = CGFloat(i) / CGFloat(steps), u = 1 - t
                    points.append(CGPoint(
                        x: u * u * current.x + 2 * u * t * control.x + t * t * to.x,
                        y: u * u * current.y + 2 * u * t * control.y + t * t * to.y
                    ))
                }
                current = to
            case .arc(let center, let radius, let from, let to):
                for i in 1...steps {
                    let a = (from + (to - from) * Double(i) / Double(steps)) * .pi / 180
                    points.append(CGPoint(x: center.x + radius * CGFloat(cos(a)), y: center.y + radius * CGFloat(sin(a))))
                }
                current = points.last ?? current
            case .close:
                points.append(start)
                current = start
            }
        }
        return points
    }
}
