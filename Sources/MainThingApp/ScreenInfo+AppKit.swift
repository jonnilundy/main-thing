import AppKit
import MainThingCore

extension ScreenInfo {
    /// Reads the fields the geometry needs from a live screen. `MAIN_THING_FAKE_NOTCH=185x32` (points)
    /// makes any screen report a centered camera housing of that size, for tests on a Mac without one.
    @MainActor
    init(_ screen: NSScreen) {
        self.init(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea
        )
        let size = Env.value("FAKE_NOTCH", in: ProcessInfo.processInfo.environment)?.split(separator: "x").compactMap { Double($0) }
        if let size, size.count == 2, size[0] > 0, size[1] > 0, CGFloat(size[0]) < frame.width {
            let (width, height) = (CGFloat(size[0]), CGFloat(size[1]))
            let side = (frame.width - width) / 2
            safeAreaTop = height
            auxiliaryTopLeft = CGRect(x: frame.minX, y: frame.maxY - height, width: side, height: height)
            auxiliaryTopRight = CGRect(x: frame.maxX - side, y: frame.maxY - height, width: side, height: height)
        }
    }
}
