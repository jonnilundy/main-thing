import AppKit
import Foundation
import MainThingCore
import SwiftUI
import os

/// Runs the color clock and the reminder flashes. One task sleeps until the next tick or the next
/// flash, whichever comes first; a tick nudges the dot's color a little toward the next step, a
/// flash bumps the sweep counter inside the shimmer animation. Nothing else runs in between.
///
/// The interval lives in UserDefaults (`reminderInterval`, seconds); a change from the menu or
/// from `defaults write` restarts the sleep. The anchor, when the current task became task 1,
/// is kept in UserDefaults by row key, so a relaunch continues the same clock.
@MainActor
final class Reminder {
    nonisolated static let key = "reminderInterval"
    nonisolated static let anchorKeyKey = "taskAnchorKey"
    nonisolated static let anchorStartKey = "taskAnchorStart"

    static var stored: Int? { UserDefaults.standard.object(forKey: key) as? Int }
    static var interval: Int { ReminderSchedule.interval(stored: stored) }

    static func store(seconds: Int) {
        UserDefaults.standard.set(seconds, forKey: key)
    }

    static var storedAnchor: ColorClock.Anchor? {
        let defaults = UserDefaults.standard
        guard let key = defaults.string(forKey: anchorKeyKey), let start = defaults.object(forKey: anchorStartKey) as? Double else { return nil }
        return ColorClock.Anchor(key: key, start: start)
    }

    static func store(anchor: ColorClock.Anchor?) {
        let defaults = UserDefaults.standard
        if let anchor {
            defaults.set(anchor.key, forKey: anchorKeyKey)
            defaults.set(anchor.start, forKey: anchorStartKey)
        } else {
            defaults.removeObject(forKey: anchorKeyKey)
            defaults.removeObject(forKey: anchorStartKey)
        }
    }

    /// The login window or the lock screen is up.
    static var screenLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Int ?? 0) != 0
    }

    private let store: TaskStore
    private let model: NotchModel
    private let log = Logger(subsystem: MainThingBundleID, category: "reminder")
    private var task: Task<Void, Never>?
    private var observer: NSKeyValueObservation?
    private var anchor: ColorClock.Anchor?
    private let sounds: Sounds?

    init(store: TaskStore, model: NotchModel, sounds: Sounds? = nil) {
        self.store = store
        self.model = model
        self.sounds = sounds
    }

    func start() {
        anchor = Reminder.storedAnchor
        anchorList()
        observeList()
        observer = UserDefaults.standard.observe(\.reminderInterval, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.restart() }
        }
    }

    private static var now: TimeInterval { Date.timeIntervalSinceReferenceDate }

    /// Task 1 changed, or the app launched: keep the anchor while the key stays, else start over.
    private func anchorList() {
        let next = ColorClock.anchor(current: anchor, firstKey: store.list.rows.first?.key, now: Reminder.now)
        let changed = next != anchor
        anchor = next
        if changed {
            Reminder.store(anchor: next)
            log.notice("task clock \(next == nil ? "cleared" : "anchored", privacy: .public)")
        }
        restart()
    }

    private func observeList() {
        withObservationTracking {
            _ = store.list
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.anchorList()
                self?.observeList()
            }
        }
    }

    private func restart() {
        task?.cancel()
        task = nil
        let interval = TimeInterval(Reminder.interval)
        log.notice("reminder every \(Int(interval), privacy: .public)s, tick \(ColorClock.tick(interval: interval), privacy: .public)s")
        show(interval: interval)
        task = Task { @MainActor [weak self] in
            // A flash may fire up to 20ms early; the next one is counted from it, never the same one again.
            var flashed = -TimeInterval.infinity
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = self.elapsed
                let tick = ColorClock.tick(interval: interval)
                let flashAt = ColorClock.nextFlash(elapsed: max(elapsed, flashed), interval: interval)
                let wait = min(tick, (flashAt ?? .infinity) - elapsed)
                try? await Task.sleep(for: .seconds(max(wait, 0.05)))
                guard !Task.isCancelled else { return }
                if let flashAt, self.elapsed + 0.02 >= flashAt {
                    flashed = flashAt
                    self.flash(step: ColorClock.state(elapsed: flashAt, interval: interval).step)
                }
                self.show(interval: interval)
            }
        }
    }

    private var elapsed: TimeInterval {
        anchor.map { Reminder.now - $0.start } ?? 0
    }

    /// The dot's color and the tooltip for now. A plain state change, no animation: the step
    /// between two ticks is about two degrees of hue.
    private func show(interval: TimeInterval) {
        let state = ColorClock.state(elapsed: elapsed, interval: interval)
        model.dotColor = Reminder.color(state.color)
        model.taskTime = anchor == nil ? "" : ColorClock.tooltip(elapsed: elapsed)
    }

    private func flash(step: Int) {
        let locked = Reminder.screenLocked
        let empty = store.list.isEmpty
        let crossingOff = !model.pending.keys.isEmpty
        guard ReminderSchedule.shouldSweep(locked: locked, empty: empty, crossingOff: crossingOff) else {
            log.notice("reminder skipped: locked \(locked, privacy: .public) empty \(empty, privacy: .public) crossing off \(crossingOff, privacy: .public)")
            return
        }
        let core = ColorClock.color(step: step)
        log.notice("reminder sweep \(self.model.sweep + 1, privacy: .public) step \(step, privacy: .public) \(core.hex, privacy: .public)")
        model.flashCore = Reminder.color(core)
        model.flashEdge = Reminder.color(ColorClock.edge(of: core))
        withAnimation(Motion.shimmer) { model.sweep += 1 }
        nudge(locked: locked)
    }

    /// With the sweep, while the card is collapsed: the hop, the halo, the sparkles and the
    /// reminder sound. The views run the hop and the halo off the counter; the sparkles run while
    /// their start is set, and it is cleared when they are over.
    private func nudge(locked: Bool) {
        let open = model.isOpen
        let editing = model.renaming != nil || model.adding
        guard ReminderNudge.shouldNudge(open: open, editing: editing, locked: locked) else {
            log.notice("reminder nudge skipped: open \(open, privacy: .public) editing \(editing, privacy: .public)")
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.nudge += 1
        log.notice("reminder nudge \(self.model.nudge, privacy: .public) reduce motion \(reduceMotion, privacy: .public)")
        let timing = ReminderNudge.timing(reduceMotion: reduceMotion)
        if timing.sparkleCount > 0 {
            let start = Date()
            model.nudgeSparkle = start
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(timing.sparkles * 1000) + 50))
                if self?.model.nudgeSparkle == start { self?.model.nudgeSparkle = nil }
            }
        }
        sounds?.reminderNudge()
    }

    static func color(_ c: OKLCH) -> Color {
        let (r, g, b) = c.srgb
        return Color(.sRGB, red: r, green: g, blue: b)
    }
}

extension UserDefaults {
    /// KVO hook for the reminder interval; the value itself is read through `Reminder.stored`.
    @objc dynamic var reminderInterval: Int { integer(forKey: Reminder.key) }
}
