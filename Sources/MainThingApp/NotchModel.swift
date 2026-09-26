import AppKit
import CoreGraphics
import Foundation
import MainThingCore
import Observation
import SwiftUI
import os

/// UI state for the notch. The task list lives in `TaskStore`.
@Observable
@MainActor
final class NotchModel {
    /// Where the notch sits and how tall it is. Recomputed on display changes.
    var geometry: NotchGeometry
    var isOpen = false
    /// Rows that were clicked and are struck through, waiting to leave.
    var pending = PendingCompletions()
    var apiBound = true
    var apiPort: UInt16
    /// Visible shape in panel coordinates, origin top left. Reported by the view.
    var shapeRect: CGRect = .zero
    /// `--open` launch flag: start open and stay open, for screenshots.
    var forceOpen = false
    /// Open card content width before the flares, from the widest title. Set by `PanelLayout`.
    var openWidth: CGFloat = OpenLayout.minimumWidth
    /// Height the rows may take before they scroll. Nil: everything fits.
    var rowsMaxHeight: CGFloat?
    /// Reminder sweeps so far. Bumped inside the shimmer animation; the fraction on the way from
    /// n to n + 1 is the band's progress across the title, and each bump pulses the dot once.
    var sweep = 0
    /// The color clock: the dot's color now, the flash colors of the step last reached, and the
    /// tooltip for the dot. Set by `Reminder`.
    var dotColor: Color = NotchMetrics.pink
    var flashCore: Color = NotchMetrics.pink
    var flashEdge: Color = NotchMetrics.pinkEdge
    var taskTime = ""
    /// The list editor window is up: the notch stays collapsed and lets every click through.
    var editorOpen = false
    /// A press on the open card moved past the click slop: its mouse up must not cross anything
    /// off. Cleared on the next mouse down.
    var dragMoved = false
    /// A tear off drag is held: the hover rules leave the notch alone until mouse up.
    var tearing = false
    /// How far the open card is stretched past its bottom edge by a tear off drag.
    var tearStretch: CGFloat = 0
    /// When the last open started, until the open layout is reported: the open latency log.
    @ObservationIgnored var openStartedAt: ContinuousClock.Instant?

    /// Which row the cursor is on and whether the next entry earns a tick.
    @ObservationIgnored private var haptics = RowHaptics()
    /// The trackpad. The hover bench swaps in a counter, so it never ticks a real trackpad.
    @ObservationIgnored var performer: any NSHapticFeedbackPerformer = NSHapticFeedbackManager.defaultPerformer
    @ObservationIgnored private let log = Logger(subsystem: MainThingBundleID, category: "hover")

    init(geometry: NotchGeometry, apiPort: UInt16) {
        self.geometry = geometry
        self.apiPort = apiPort
    }

    /// A row's hover changed. A light trackpad tick once per row the cursor enters, never while
    /// the rows animate under it. Only Force Touch trackpads make a sound of it.
    func rowHover(_ key: String, number: Int, inside: Bool) {
        if inside {
            let tick = haptics.enter(key, at: Date.timeIntervalSinceReferenceDate)
            if tick {
                performer.perform(.alignment, performanceTime: .now)
            }
            log.debug("row \(number, privacy: .public) entered, tick \(tick, privacy: .public)")
        } else {
            haptics.exit(key)
            log.debug("row \(number, privacy: .public) left")
        }
    }

    /// The rows are about to move: no ticks for the rows that slide under a still cursor.
    func rowsAnimate() {
        haptics.listAnimates(at: Date.timeIntervalSinceReferenceDate)
    }
}
