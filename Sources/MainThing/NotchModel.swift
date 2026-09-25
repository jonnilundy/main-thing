import AppKit
import CoreGraphics
import Foundation
import MainThingCore
import Observation
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

    /// Which row the cursor is on and whether the next entry earns a tick.
    @ObservationIgnored private var haptics = RowHaptics()
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
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
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
