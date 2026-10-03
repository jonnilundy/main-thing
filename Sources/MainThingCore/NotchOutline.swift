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

/// The outline under a hardware notch: the menu bar row above the card and the card, one closed
/// path, so the camera notch and the card read as one black shape.
///
/// The shape's top edge is the screen top, `bridgeHeight` above the card's top edge (the menu bar's
/// bottom edge), and its sides are the card's own current sides, straight down from the top to the
/// bottom corners. Collapsed, the card is exactly as wide as the camera notch, so the shape is the
/// notch's own width. There is no step anywhere: while the card's width springs, the top edge
/// moves with it, because it is the same two sides.
///
/// Open, the top corners flare out concave, the plain notch's flare (a quarter curve with its
/// control on the corner), so the card fills the menu bar row above it. The flare grows with
/// `openness` (0 to 1): at 0 the top corners are square, at 1 they are full size.
public enum NotchOutline {
    /// The outline in `rect`, the card's frame with the flare padding on both sides, y down.
    /// `rect.minY` is the card's top edge. The shape rises `bridgeHeight` above it. The card's sides
    /// are `padding` in from the rect, as the plain notch's; `bottomRadius` rounds its bottom
    /// corners. `openness` (0 to 1) grows the flares at the top corners.
    public static func bridged(
        in rect: CGRect, padding: CGFloat = NotchGeometry.flare, bottomRadius: CGFloat,
        bridgeHeight: CGFloat, openness: CGFloat = 0
    ) -> [OutlineSegment] {
        let top = rect.minY
        let bottom = max(rect.maxY, top)
        let left = rect.minX + padding
        let right = max(rect.maxX - padding, left)
        let shapeTop = top - bridgeHeight
        // A card too short for its corners (while it grows out of an empty notch) gets smaller ones.
        let b = max(min(bottomRadius, (right - left) / 2, bottom - top), 0)
        // The flare ends above the bottom corners. With no bridge (hidden under a hardware notch,
        // the card is the whole menu bar row) it runs down into the card, as the plain notch's.
        let flare = min(padding * min(max(openness, 0), 1), max(bottom - b - shapeTop, 0))

        var path: [OutlineSegment] = [
            .move(CGPoint(x: left - flare, y: shapeTop)),
            .line(CGPoint(x: right + flare, y: shapeTop)),
        ]
        if flare > 0 {
            path.append(.quad(to: CGPoint(x: right, y: shapeTop + flare), control: CGPoint(x: right, y: shapeTop)))
        }
        path.append(.line(CGPoint(x: right, y: bottom - b)))
        path.append(.arc(center: CGPoint(x: right - b, y: bottom - b), radius: b, from: 0, to: 90))
        path.append(.line(CGPoint(x: left + b, y: bottom)))
        path.append(.arc(center: CGPoint(x: left + b, y: bottom - b), radius: b, from: 90, to: 180))
        if flare > 0 {
            path.append(.line(CGPoint(x: left, y: shapeTop + flare)))
            path.append(.quad(to: CGPoint(x: left - flare, y: shapeTop), control: CGPoint(x: left, y: shapeTop)))
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
