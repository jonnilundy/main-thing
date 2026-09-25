import CoreGraphics
import Foundation
import MainThingCore
import Observation

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

    init(geometry: NotchGeometry, apiPort: UInt16) {
        self.geometry = geometry
        self.apiPort = apiPort
    }
}
