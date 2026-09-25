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
    /// The done circle is filled and the completion is about to run.
    var doneArmed = false
    var apiBound = true
    var apiPort: UInt16
    /// Visible shape in panel coordinates, origin top left. Reported by the view.
    var shapeRect: CGRect = .zero
    /// `--open` launch flag: start open and stay open, for screenshots.
    var forceOpen = false

    init(geometry: NotchGeometry, apiPort: UInt16) {
        self.geometry = geometry
        self.apiPort = apiPort
    }
}
