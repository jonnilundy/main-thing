import CoreGraphics
import Foundation

/// The reminder shimmer's schedule and shape. Pure rules; the app owns the sleeping task and the
/// animation. Every `interval` seconds a pink band sweeps across the current task's title, left to
/// right, and the dot pulses once. Nothing runs between sweeps.
public enum ReminderSchedule {
    /// 3 minutes.
    public static let defaultInterval = 180
    /// The Reminder submenu, in minutes. 0 is Off.
    public static let menuMinutes = [0, 1, 3, 5, 10]
    /// The band crosses the title in about 1.4s.
    public static let sweepDuration: Double = 1.4
    /// The band is this share of the title's width.
    public static let bandShare: CGFloat = 0.35

    /// The interval in seconds from the stored value: nothing or nonsense is the default, 0 is Off,
    /// any other positive number counts (tests set 5).
    public static func interval(stored: Int?) -> Int {
        guard let stored, stored >= 0 else { return defaultInterval }
        return stored
    }

    /// When the next sweep is due after `last`. Nil when the reminder is off.
    public static func nextFire(after last: TimeInterval, interval: Int) -> TimeInterval? {
        interval > 0 ? last + TimeInterval(interval) : nil
    }

    /// A due sweep runs unless the screen is locked, the list is empty, or a cross off is drawing.
    /// A skipped sweep is not retried; the next one is a full interval later.
    public static func shouldSweep(locked: Bool, empty: Bool, crossingOff: Bool) -> Bool {
        !locked && !empty && !crossingOff
    }

    public static func label(minutes: Int) -> String {
        switch minutes {
        case 0: "Off"
        case 1: "1 minute"
        default: "\(minutes) minutes"
        }
    }

    /// The sweep counter animates from n to n + 1; the fraction is the band's progress, 0 at rest.
    public static func phase(of sweep: Double) -> Double {
        sweep - sweep.rounded(.down)
    }

    /// The band's left and right edges at `phase` 0...1 over a title `width` wide, from the title's
    /// left edge: entirely off the left end at 0, entirely off the right end at 1.
    public static func band(phase: Double, width: CGFloat) -> (start: CGFloat, end: CGFloat) {
        let bandWidth = width * bandShare
        let start = -bandWidth + CGFloat(phase) * (width + bandWidth)
        return (start, start + bandWidth)
    }
}
