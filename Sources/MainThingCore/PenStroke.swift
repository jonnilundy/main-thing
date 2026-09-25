import CoreGraphics
import Foundation

/// The hand drawn cross off: one pen stroke per text line. Pure geometry, so the app only turns
/// the samples into a path and the checks can pin the shape down.
///
/// A stroke starts a few points before the first glyph and overshoots past the last. It is tilted
/// about a degree, the other way on every other line, wobbles a little in a way that is the same
/// every time for the same row, and is thicker in the middle than at its ends.
public enum PenStroke {
    /// Points before the first glyph and past the last.
    public static let overshootStart: CGFloat = 4
    public static let overshootEnd: CGFloat = 6
    /// Tilt in degrees. Even lines fall to the right, odd lines rise. Under a degree, and the
    /// drop is capped so a long stroke stays inside the middle band of the lowercase letters.
    public static let tiltDegrees: Double = 0.8
    public static let maxTilt: CGFloat = 1.5
    /// Wobble amplitude in points.
    public static let wobble: CGFloat = 0.5
    /// Samples along one stroke.
    public static let sampleCount = 28
    /// Width at the ends as a share of the width in the middle.
    public static let endShare: CGFloat = 0.3
    /// Seconds per line, the pen moving.
    public static let secondsPerLine: Double = 0.22

    public struct Sample: Equatable, Sendable {
        public var point: CGPoint
        public var width: CGFloat

        public init(point: CGPoint, width: CGFloat) {
            self.point = point
            self.width = width
        }
    }

    /// A seed from the row key and the line index. FNV-1a, so it is the same on every run.
    public static func seed(key: String, line: Int) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        hash ^= UInt64(truncatingIfNeeded: line &+ 1)
        hash = hash &* 0x0000_0100_0000_01b3
        return hash
    }

    /// The pen's path across one text line. `from` and `to` are the glyph extents on the strike
    /// line; the stroke reaches `overshootStart` before and `overshootEnd` past them.
    public static func centerline(from: CGPoint, to: CGPoint, line: Int, seed: UInt64, thickness: CGFloat) -> [Sample] {
        var random = SplitMix(seed: seed)
        let start = CGPoint(x: from.x - overshootStart, y: from.y)
        let end = CGPoint(x: to.x + overshootEnd, y: to.y)
        let length = max(end.x - start.x, 1)
        // Tilt: the far end moves down (even lines) or up (odd lines).
        let tilt = min(CGFloat(tan(tiltDegrees * .pi / 180)) * length, maxTilt) * (line.isMultiple(of: 2) ? 1 : -1)
        // Wobble: a slow wave plus a little grain, both seeded.
        let waves = 1.5 + random.next() * 1.5
        let phase = random.next() * 2 * .pi
        var samples: [Sample] = []
        samples.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            let t = CGFloat(i) / CGFloat(sampleCount - 1)
            let wave = sin(Double(t) * 2 * .pi * waves + phase)
            let grain = (random.next() - 0.5) * 0.5
            // The pen lands and lifts on the line: no wobble at the very ends.
            let envelope = sin(Double(t) * .pi)
            let y = start.y + tilt * t + wobble * CGFloat(min(max(wave + grain, -1), 1) * envelope)
            let width = thickness * (endShare + (1 - endShare) * CGFloat(pow(envelope, 0.7)))
            samples.append(Sample(point: CGPoint(x: start.x + length * t, y: y), width: width))
        }
        return samples
    }

    /// The polygon of the ink laid down so far. `progress` 0 is nothing, 1 the whole stroke.
    /// Points run along the top edge, then back along the bottom edge.
    public static func outline(_ samples: [Sample], progress: Double) -> [CGPoint] {
        guard samples.count >= 2, progress > 0 else { return [] }
        let p = min(max(progress, 0), 1)
        let position = p * Double(samples.count - 1)
        let last = Int(position.rounded(.down))
        var visible = Array(samples[0...min(last, samples.count - 1)])
        if last < samples.count - 1 {
            let f = CGFloat(position - Double(last))
            let a = samples[last], b = samples[last + 1]
            visible.append(Sample(
                point: CGPoint(x: a.point.x + (b.point.x - a.point.x) * f, y: a.point.y + (b.point.y - a.point.y) * f),
                width: a.width + (b.width - a.width) * f
            ))
        }
        guard visible.count >= 2 else { return [] }
        // One normal for the whole stroke: the wobble is far too small to bend it.
        let first = samples.first!.point, tail = samples.last!.point
        let dx = tail.x - first.x, dy = tail.y - first.y
        let len = max(sqrt(dx * dx + dy * dy), 1)
        let nx = -dy / len, ny = dx / len
        var top: [CGPoint] = []
        var bottom: [CGPoint] = []
        for s in visible {
            top.append(CGPoint(x: s.point.x + nx * s.width / 2, y: s.point.y + ny * s.width / 2))
            bottom.append(CGPoint(x: s.point.x - nx * s.width / 2, y: s.point.y - ny * s.width / 2))
        }
        return top + bottom.reversed()
    }

    /// Fast attack, slower finish, like a pen that lands and then slows into the lift.
    public static func eased(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return 1 - pow(1 - x, 3)
    }

    /// How far the ink on `line` has got for a whole row progress of 0...lineCount.
    public static func lineProgress(_ progress: Double, line: Int) -> Double {
        eased(progress - Double(line))
    }

    /// Where the pen lifts on the last line, for the blot.
    public static func liftPoint(_ samples: [Sample]) -> CGPoint? {
        samples.last?.point
    }

    /// Deterministic 64 bit generator for the wobble.
    public struct SplitMix {
        private var state: UInt64

        public init(seed: UInt64) { state = seed }

        /// 0..<1
        public mutating func next() -> Double {
            state &+= 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
    }
}
