import AppKit
import CoreGraphics
import Foundation
import MainThingCore
import Observation
import SwiftUI
import os

/// A task held by its handle. `offset` is the pointer's travel since the press, 1:1; `target`
/// is the index it would land on. The others show at `Reorder.place`.
struct CardDrag: Equatable {
    var key: String
    var from: Int
    var target: Int
    var offset: CGFloat
}

/// The long press menu: the task, its frame in card coordinates, the item under the pointer.
struct CardMenu: Equatable {
    var key: String
    var frame: CGRect
    var hovered: RowMenu.Item?
}

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
    /// When the last open started, until the open layout is reported: the open latency log.
    @ObservationIgnored var openStartedAt: ContinuousClock.Instant?
    /// The slot the pointer is over while open, from the one tracker in `CardController`. The
    /// row views read it; they have no hover tracking of their own.
    var hover: CardSlot = .none
    /// The slot under a press, until the release: it dims a touch, the pen touching the paper.
    var pressed: CardSlot = .none
    /// Hover changes fade (Motion.preview). The gap probe turns this off to read the drawn state at once.
    @ObservationIgnored var hoverAnimates = true
    /// How far the rows are scrolled, for mapping the pointer to a row. Not observed.
    @ObservationIgnored var rowsScroll: CGFloat = 0
    /// A task held by its number or dot: it follows the pointer, the others make room.
    var drag: CardDrag?
    /// The long press menu, on the task it was opened on.
    var menu: CardMenu?
    /// The task whose title is a text field, and the text in it. Kept by key, so a list change
    /// from the API while the field is open still lands the rename on the right task.
    var renaming: String?
    var renameText = ""
    /// The add card is a text field, and the text in it.
    var adding = false
    var addText = ""
    /// The last discarded task, while its Undo shows.
    var discarded: Discarded?
    /// A reorder or a rename just landed: rows come and go without their transitions.
    var quietRows = false
    /// The row key (or "add", "undo") the pointer is on, for the haptics.
    @ObservationIgnored private var hoverKey: String?

    /// Which row the cursor is on and whether the next entry earns a tick.
    @ObservationIgnored private var haptics = RowHaptics()
    /// The trackpad. The hover bench swaps in a counter, so it never ticks a real trackpad.
    @ObservationIgnored var performer: any NSHapticFeedbackPerformer = NSHapticFeedbackManager.defaultPerformer
    @ObservationIgnored private let log = Logger(subsystem: MainThingBundleID, category: "hover")

    init(geometry: NotchGeometry, apiPort: UInt16) {
        self.geometry = geometry
        self.apiPort = apiPort
    }

    /// The pointer is over `slot`, which holds `key`. A light trackpad tick once per row the
    /// cursor enters, never while the rows animate under it. Only Force Touch trackpads make a
    /// sound of it. A new key in the same slot (a row left under a still cursor) is a new row.
    func setHover(_ slot: CardSlot, key: String?, animated: Bool) {
        guard slot != hover || key != hoverKey else { return }
        if let old = hoverKey, old != key {
            haptics.exit(old)
            log.debug("left \(old, privacy: .private)")
        }
        if let key, key != hoverKey {
            let tick = haptics.enter(key, at: Date.timeIntervalSinceReferenceDate)
            if tick { performer.perform(.alignment, performanceTime: .now) }
            log.debug("entered \(String(describing: slot), privacy: .public), tick \(tick, privacy: .public)")
        }
        hoverKey = key
        if slot != hover {
            withAnimation(animated && hoverAnimates ? Motion.preview : nil) { hover = slot }
        }
    }

    /// A field in the card holds text, or a drag or menu is up: the card stays open when the
    /// pointer leaves.
    var holdsOpen: Bool {
        drag != nil || renaming != nil || (adding && !addText.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// The row the cursor is on, band included: the last entry not followed by its exit.
    var hoveredRow: String? { haptics.current }

    /// The rows are about to move: no ticks for the rows that slide under a still cursor.
    func rowsAnimate() {
        haptics.listAnimates(at: Date.timeIntervalSinceReferenceDate)
    }
}

extension NotchModel {
    /// How far task `index` shows from its resting place while a task is held: the held one
    /// follows the pointer, the ones it passed move one place toward where it came from.
    /// `centers` are the tasks' resting centers.
    func shift(ofTask index: Int, centers: [CGFloat]) -> CGFloat {
        guard let drag, centers.indices.contains(index), centers.indices.contains(drag.target) else { return 0 }
        if index == drag.from { return drag.offset }
        return centers[Reorder.place(of: index, from: drag.from, to: drag.target)] - centers[index]
    }
}
