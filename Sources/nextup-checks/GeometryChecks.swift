import CoreGraphics
import Foundation
import NextUpCore

@MainActor
func runGeometryChecks() {
    section("NotchGeometry")

    // Studio Display, clamshell: 2560x1440, 30pt menu bar, no hardware notch.
    let studio = ScreenInfo(
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410)
    )
    let s = NotchGeometry(screen: studio)
    check("studio: menu bar 30", s.menuBarHeight == 30)
    check("studio: no hardware notch", s.hasHardwareNotch == false && s.hardwareNotchWidth == 0 && s.safeAreaTop == 0)
    check("studio: notch height is the menu bar", s.notchHeight == 30)
    check("studio: title band is the whole row", s.titleBandHeight == 30)
    check("studio: plain minimum width", s.minimumWidth == 140)
    check("studio: panel centered at 1280", s.panelFrame.midX == 1280 && s.panelFrame.width == 800)
    check("studio: panel top on the screen edge", s.panelFrame.maxY == 1440 && s.panelFrame.height == 260)
    check("studio: panel x 880 y 1180", s.panelFrame.origin == CGPoint(x: 880, y: 1180))

    // 14 inch MacBook Pro: 1512x982, safe top 32, auxiliary areas leave a 185pt housing.
    let mbp = ScreenInfo(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
        auxiliaryTopRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32)
    )
    check("mbp: hardware notch rect", mbp.hardwareNotch == CGRect(x: 663.5, y: 950, width: 185, height: 32))
    let m = NotchGeometry(screen: mbp)
    check("mbp: menu bar 32", m.menuBarHeight == 32)
    check("mbp: hardware notch width 185", m.hasHardwareNotch && m.hardwareNotchWidth == 185)
    check("mbp: safe top 32", m.safeAreaTop == 32)
    check("mbp: notch height is safe top plus the 24pt band", m.notchHeight == 56)
    check("mbp: title band 24", m.titleBandHeight == 24)
    check("mbp: minimum width matches the housing minus the flares", m.minimumWidth == 169)
    check("mbp: panel centered at 756", m.panelFrame.midX == 756)
    check("mbp: panel top on the screen edge", m.panelFrame.maxY == 982)
    check("mbp: panel x 356 y 722", m.panelFrame.origin == CGPoint(x: 356, y: 722))

    // Secondary screen placed to the right, with its own origin.
    let secondary = ScreenInfo(
        frame: CGRect(x: 2560, y: 200, width: 1512, height: 982),
        visibleFrame: CGRect(x: 2560, y: 200, width: 1512, height: 950),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 2560, y: 1150, width: 663.5, height: 32),
        auxiliaryTopRight: CGRect(x: 3408.5, y: 1150, width: 663.5, height: 32)
    )
    let sec = NotchGeometry(screen: secondary)
    check("offset screen: panel follows the screen origin", sec.panelFrame.origin == CGPoint(x: 2916, y: 922) && sec.panelFrame.maxY == 1182)
    check("offset screen: housing width still 185", sec.hardwareNotchWidth == 185)

    // Edge cases.
    let flat = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1000, height: 500), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 500))
    check("no menu bar reported: falls back to 30", NotchGeometry(screen: flat).notchHeight == 30)
    let noAux = ScreenInfo(frame: mbp.frame, visibleFrame: mbp.visibleFrame, safeAreaTop: 32)
    check("safe top without auxiliary areas: treated as no hardware notch", NotchGeometry(screen: noAux).hasHardwareNotch == false)
    check("safe top without auxiliary areas: notch height is the menu bar", NotchGeometry(screen: noAux).notchHeight == 32)

    section("Screen choice")
    check("notch screen wins over the primary", NotchGeometry.chooseScreen([studio, mbp]) == 1)
    check("notch screen first stays first", NotchGeometry.chooseScreen([mbp, studio]) == 0)
    check("no notch screen: the primary", NotchGeometry.chooseScreen([studio]) == 0)
    check("two plain screens: the first", NotchGeometry.chooseScreen([studio, flat]) == 0)
    check("no screens: nil", NotchGeometry.chooseScreen([]) == nil)
}
