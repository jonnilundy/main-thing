import CoreGraphics
import Foundation
import MainThingCore

/// The drawn black against the real camera cutout of a 14 inch MacBook Pro, in every display mode.
///
/// Measured on a real panel (Mac16,8, 3024 x 1964 px) with a photo of a pixel ruler: the cutout
/// runs from panel pixel 1325 to 1697 and is 64 px tall. macOS reported 1326 to 1696 at native.
/// The photo resolves about 1 px, so the checks use 1324 to 1698. In a scaled mode a point is not
/// a whole number of panel pixels, and the reported areas can miss the glass by up to 1 pt; the
/// checks assume that worst case on both sides.
@MainActor
func runPanelChecks() {
    section("Real cutout, 14 inch MacBook Pro")
    let panelWidth: CGFloat = 3024
    let cutout = (left: CGFloat(1324), right: CGFloat(1698), height: CGFloat(64))
    // The display modes with the notch area ("looks like" sizes), from the panel's mode list.
    let modes: [(width: CGFloat, height: CGFloat)] = [(1024, 665), (1147, 745), (1352, 878), (1512, 982), (1800, 1169)]
    let bleed = NotchGeometry.housingBleed
    for mode in modes {
        let pointsPerPixel = mode.width / panelWidth
        let glassLeft = cutout.left * pointsPerPixel
        let glassRight = cutout.right * pointsPerPixel
        let top = (cutout.height * pointsPerPixel).rounded(.up)
        let name = "\(Int(mode.width)) x \(Int(mode.height))"
        // Reported 1 pt inside the glass on both sides (the worst miss), and 1 pt outside it.
        for miss: CGFloat in [1, -1] {
            let left = glassLeft + miss
            let right = glassRight - miss
            let screen = ScreenInfo(
                frame: CGRect(x: 0, y: 0, width: mode.width, height: mode.height),
                visibleFrame: CGRect(x: 0, y: 0, width: mode.width, height: mode.height - top),
                safeAreaTop: top,
                auxiliaryTopLeft: CGRect(x: 0, y: mode.height - top, width: left, height: top),
                auxiliaryTopRight: CGRect(x: right, y: mode.height - top, width: mode.width - right, height: top)
            )
            let g = NotchGeometry(screen: screen)
            guard let bridge = g.bridgeRect else {
                check("\(name): a hardware notch is found", false)
                continue
            }
            let drawnLeft = g.panelFrame.minX + bridge.minX
            let drawnRight = drawnLeft + bridge.width
            let side = miss > 0 ? "reported 1 pt inside the glass" : "reported 1 pt outside the glass"
            check("\(name), \(side): the black covers the cutout's left edge", drawnLeft <= glassLeft)
            check("\(name), \(side): the black covers the cutout's right edge", drawnRight >= glassRight)
            check("\(name), \(side): the black reaches at most the bleed and 1 pt past the glass",
                  glassLeft - drawnLeft <= bleed + 1 && drawnRight - glassRight <= bleed + 1)
        }
    }
}
