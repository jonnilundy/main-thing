import CoreGraphics
import Foundation

/// The reminder nudge: with each sweep, while the notch is collapsed, the shape hops (grows a
/// little from the top and springs back), a halo in the step's color fades in and out around its
/// outline, and sparkles pop along the title. Pure rules; the app owns the views. Everything runs
/// off one trigger, so nothing draws between nudges.
public enum ReminderNudge {
    /// The shape grows this share at the hop's peak, down from its top edge.
    public static let growth: CGFloat = 0.07
    /// The most the hop may widen the shape on each side where it sits in the menu bar row: the
    /// whole shape without a hardware notch, the bridge under one.
    public static let maxSideGrowth: CGFloat = 3

    /// The hop's horizontal and vertical scale at its peak, anchored at the top center. `width`
    /// and `height` are the whole shape's; `menuBarWidth` is the part of it in the menu bar row.
    /// The height grows by `growth`; the width by `growth` too, unless that would push the menu
    /// bar part more than `maxSideGrowth` out on a side.
    public static func hopScale(width: CGFloat, height: CGFloat, menuBarWidth: CGFloat) -> (x: CGFloat, y: CGFloat) {
        let widest = max(width, menuBarWidth, 1)
        let x = 1 + min(growth, 2 * maxSideGrowth / widest)
        return (x, height > 0 ? 1 + growth : 1)
    }

    /// How far the menu bar part reaches out on each side at a scale.
    public static func sideGrowth(menuBarWidth: CGFloat, scaleX: CGFloat) -> CGFloat {
        menuBarWidth * (scaleX - 1) / 2
    }

    /// Runs with the sweep unless the card is open, a field is open, or the screen is locked (the
    /// sweep's own rules still apply on top).
    public static func shouldNudge(open: Bool, editing: Bool, locked: Bool) -> Bool {
        !open && !editing && !locked
    }

    /// The nudge's schedule in seconds from the sweep's start.
    public struct Timing: Equatable, Sendable {
        /// The shape grows to its peak.
        public var hopRise: Double
        /// It springs back and settles.
        public var hopSettle: Double
        /// The halo fades in, stays, and fades out.
        public var glowIn: Double
        public var glowHold: Double
        public var glowOut: Double
        /// The halo's opacity at its peak.
        public var glowPeak: Double
        /// Sparkles: they start after `sparkleDelay`, one every `sparkleStagger`, each `sparkleLife` long.
        public var sparkleDelay: Double
        public var sparkleCount: Int
        public var sparkleStagger: Double
        public var sparkleLife: Double

        public var hop: Double { hopRise + hopSettle }
        public var glow: Double { glowIn + glowHold + glowOut }
        /// 0 when there are no sparkles.
        public var sparkles: Double {
            sparkleCount > 0 ? sparkleDelay + Double(sparkleCount - 1) * sparkleStagger + sparkleLife : 0
        }
        /// When the last part ends.
        public var total: Double { max(hop, glow, sparkles) }
    }

    /// Full motion: hop, halo and sparkles in about 1.4s, the sweep's length. Reduce Motion: no
    /// hop and no sparkles, a slower and softer halo.
    public static func timing(reduceMotion: Bool) -> Timing {
        if reduceMotion {
            return Timing(
                hopRise: 0, hopSettle: 0,
                glowIn: 0.5, glowHold: 0.3, glowOut: 0.8, glowPeak: 0.6,
                sparkleDelay: 0, sparkleCount: 0, sparkleStagger: 0, sparkleLife: 0
            )
        }
        return Timing(
            hopRise: 0.16, hopSettle: 0.64,
            glowIn: 0.2, glowHold: 0.35, glowOut: 0.85, glowPeak: 0.9,
            sparkleDelay: 0.1, sparkleCount: 9, sparkleStagger: 0.045, sparkleLife: 0.4
        )
    }

    /// The halo's opacity `t` seconds into the nudge: an ease out rise, a hold, an ease out fade.
    /// 0 before and after. The views run the same curve as keyframes; this is its reference.
    public static func glowOpacity(at t: Double, timing: Timing) -> Double {
        guard t > 0, t < timing.glow else { return 0 }
        let easeOut = { (x: Double) in 1 - (1 - x) * (1 - x) }
        if t < timing.glowIn { return timing.glowPeak * easeOut(t / timing.glowIn) }
        if t < timing.glowIn + timing.glowHold { return timing.glowPeak }
        let x = (t - timing.glowIn - timing.glowHold) / timing.glowOut
        return timing.glowPeak * (1 - easeOut(x))
    }
}

/// The sound with the reminder nudge: a Cuelume cue or none, none by default.
public enum ReminderSound {
    /// The UserDefaults key. Nothing stored is None.
    public static let key = "reminderSound"
    public static let noneKey = LinkSound.noneKey
    /// The Reminder sound picker: None, then every cue.
    public static let options: [Cue?] = LinkSound.options

    /// The cue to play, nil for None. Nothing stored and a cue this version does not have are None.
    public static func resolve(stored: String?) -> Cue? {
        guard let stored else { return nil }
        return Cue(stored: stored)
    }

    /// The UserDefaults value.
    public static func stored(_ cue: Cue?) -> String { cue?.stored ?? noneKey }

    public static func displayName(_ cue: Cue?) -> String { LinkSound.displayName(cue) }
}
