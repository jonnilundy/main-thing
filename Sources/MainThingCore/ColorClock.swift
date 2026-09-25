import Foundation

/// A color in OKLCH: perceptual lightness 0...1, chroma, hue in degrees.
public struct OKLCH: Equatable, Sendable {
    public var l: Double
    public var c: Double
    public var h: Double

    public init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }

    /// From sRGB components 0...1 (Björn Ottosson's OKLab).
    public init(red: Double, green: Double, blue: Double) {
        let r = OKLCH.linear(red), g = OKLCH.linear(green), b = OKLCH.linear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let hue = atan2(bb, a) * 180 / .pi
        self.init(l: L, c: hypot(a, bb), h: hue < 0 ? hue + 360 : hue)
    }

    /// From a hex like 0xFF4F9A.
    public init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Linear sRGB components, possibly outside 0...1 when the color is out of gamut.
    public var linearRGB: (r: Double, g: Double, b: Double) {
        let L = self.l
        let a = c * cos(h * .pi / 180), bb = c * sin(h * .pi / 180)
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * bb, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * bb, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * bb, 3)
        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    public var inGamut: Bool {
        let (r, g, b) = linearRGB
        return (-1e-6...1 + 1e-6).contains(r) && (-1e-6...1 + 1e-6).contains(g) && (-1e-6...1 + 1e-6).contains(b)
    }

    /// sRGB components 0...1, clamped.
    public var srgb: (red: Double, green: Double, blue: Double) {
        let (r, g, b) = linearRGB
        return (OKLCH.gamma(r), OKLCH.gamma(g), OKLCH.gamma(b))
    }

    /// The same lightness and hue with the chroma reduced until the color fits sRGB.
    public var fitted: OKLCH {
        if inGamut { return self }
        var low = 0.0, high = c
        for _ in 0..<32 {
            let mid = (low + high) / 2
            if OKLCH(l: l, c: mid, h: h).inGamut { low = mid } else { high = mid }
        }
        return OKLCH(l: l, c: low, h: h)
    }

    public var hex: String {
        let (r, g, b) = srgb
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func gamma(_ c: Double) -> Double {
        let v = min(max(c, 0), 1)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
}

/// The dot is a clock for time on the current task. Ten hues sit evenly around the OKLCH wheel
/// from the brand pink, all at the pink's lightness. Every reminder interval the hue steps on and
/// the band flashes in that step's color, so the same color coming back means ten intervals have
/// passed (30 minutes at the default). Between flashes the dot drifts toward the next step in
/// small ticks the eye does not see. Pure rules; the app keeps the anchor and the sleeping task.
public enum ColorClock {
    public static let steps = 10
    /// #FF4F9A. Step 0 is its hue; every step keeps its lightness.
    public static let brand = OKLCH(hex: 0xFF4F9A)
    /// The band's edge next to the core: lighter and softer, the same hue (#FF9ECB next to the pink).
    public static let edgeLift = 0.12
    public static let edgeChroma = 0.58

    /// When the current task became task 1, by row key. Kept across relaunches while the key stays.
    public struct Anchor: Equatable, Sendable {
        public var key: String
        public var start: TimeInterval

        public init(key: String, start: TimeInterval) {
            self.key = key
            self.start = start
        }
    }

    /// The anchor after a list change or a launch: the same one while task 1 keeps its key, a new
    /// one at `now` when task 1 changed by a cross off, a reorder or a new list, none when empty.
    public static func anchor(current: Anchor?, firstKey: String?, now: TimeInterval) -> Anchor? {
        guard let firstKey else { return nil }
        if let current, current.key == firstKey { return current }
        return Anchor(key: firstKey, start: now)
    }

    /// The hue of step `k`, 36 degrees on from the last.
    public static func hue(step: Int) -> Double {
        let h = brand.h + 360 / Double(steps) * Double(((step % steps) + steps) % steps)
        return h.truncatingRemainder(dividingBy: 360)
    }

    /// A step's color: the brand lightness and chroma at that hue, chroma reduced where sRGB
    /// cannot show it. The lightness is what keeps every step equally bright.
    public static func color(step: Int) -> OKLCH {
        OKLCH(l: brand.l, c: brand.c, h: hue(step: step)).fitted
    }

    /// The dot between steps: `progress` 0...1 of the way from step `k`'s hue to the next.
    public static func color(step: Int, progress: Double) -> OKLCH {
        let p = min(max(progress, 0), 1)
        let h = (hue(step: step) + 360 / Double(steps) * p).truncatingRemainder(dividingBy: 360)
        return OKLCH(l: brand.l, c: brand.c, h: h).fitted
    }

    public static func edge(of color: OKLCH) -> OKLCH {
        OKLCH(l: min(color.l + edgeLift, 1), c: color.c * edgeChroma, h: color.h).fitted
    }

    public struct State: Equatable, Sendable {
        public var step: Int
        public var progress: Double
        public var color: OKLCH

        public init(step: Int, progress: Double, color: OKLCH) {
            self.step = step
            self.progress = progress
            self.color = color
        }
    }

    /// Where the clock stands `elapsed` seconds into the task. Off (interval 0): step 0, the pink.
    public static func state(elapsed: TimeInterval, interval: TimeInterval) -> State {
        guard interval > 0, elapsed > 0 else { return State(step: 0, progress: 0, color: color(step: 0)) }
        let whole = (elapsed / interval).rounded(.down)
        let step = Int(whole.truncatingRemainder(dividingBy: Double(steps)))
        let progress = elapsed / interval - whole
        return State(step: step, progress: progress, color: color(step: step, progress: progress))
    }

    /// When the next flash is due after `elapsed` seconds. Nil when off.
    public static func nextFlash(elapsed: TimeInterval, interval: TimeInterval) -> TimeInterval? {
        guard interval > 0 else { return nil }
        return ((max(elapsed, 0) / interval).rounded(.down) + 1) * interval
    }

    /// How often the dot's color is refreshed: 18 ticks per interval, never more than one per
    /// 10s. Off: once a minute, for the tooltip.
    public static func tick(interval: TimeInterval) -> TimeInterval {
        guard interval > 0 else { return 60 }
        return max(min(10, interval / Double(steps * 2 - 2)), 0.25)
    }

    /// "On this task for 24 min", or hours and minutes past an hour.
    public static func tooltip(elapsed: TimeInterval) -> String {
        let minutes = Int((max(elapsed, 0) / 60).rounded(.down))
        switch minutes {
        case ..<1: return "On this task for under a minute"
        case ..<60: return "On this task for \(minutes) min"
        default:
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "On this task for \(h) h" : "On this task for \(h) h \(m) min"
        }
    }
}
