import AppKit
import NextUpCore

extension ScreenInfo {
    /// Reads the fields the geometry needs from a live screen.
    @MainActor
    init(_ screen: NSScreen) {
        self.init(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea
        )
    }
}
