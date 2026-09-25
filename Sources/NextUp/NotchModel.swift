import CoreGraphics
import Foundation
import Observation

/// UI state for the notch. The task list lives in `TaskStore`.
@Observable
@MainActor
final class NotchModel {
    var notchHeight: CGFloat
    var isOpen = false
    /// The done circle is filled and the completion is about to run.
    var doneArmed = false
    var apiBound = true
    var apiPort: UInt16
    /// Visible shape in panel coordinates, origin top left. Reported by the view.
    var shapeRect: CGRect = .zero
    /// `--open` launch flag: start open and stay open, for screenshots.
    var forceOpen = false

    init(notchHeight: CGFloat, apiPort: UInt16) {
        self.notchHeight = notchHeight
        self.apiPort = apiPort
    }
}
