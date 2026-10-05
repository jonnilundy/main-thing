import CoreGraphics
import Foundation
import MainThingCore

@MainActor
func runGeometryChecks() {
    section("NotchGeometry")

    // Studio Display as the primary: 2560x1440, 30pt menu bar, no hardware notch.
    let studio = ScreenInfo(
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410)
    )
    let s = NotchGeometry(screen: studio)
    check("studio: mode is in the menu bar", s.mode == .inMenuBar && s.hasHardwareNotch == false)
    check("studio: menu bar 30", s.menuBarHeight == 30)
    check("studio: centered on the screen", s.centerX == 1280 && s.panelFrame.midX == 1280)
    check("studio: panel top is the screen top", s.panelFrame.maxY == 1440)
    check("studio: panel x 880 y 1180, 800x260", s.panelFrame == CGRect(x: 880, y: 1180, width: 800, height: 260))
    check("studio: collapsed height is the menu bar height", s.notchHeight == 30)
    check("studio: minimum content width is 185 minus the flares", s.minimumWidth == 169)
    let plain = s.collapsedShapeFrame(contentWidth: 100)
    check("studio: empty or short title gives the 185pt width", plain.width == 185 && plain.height == 30)
    check("studio: collapsed shape starts at the panel top", plain.minY == 0 && plain.maxY == 30)
    check("studio: no bridge, card top 0", s.bridgeRect == nil && s.cardTop == 0 && s.bridgeOffset == 0)
    check("studio: an empty list still draws the plain notch", s.drawsCollapsed(taskCount: 0) && s.drawsCollapsed(taskCount: 1))
    check("studio: collapsed shape centered in the panel", abs(plain.midX - 400) <= 0.5)
    let long = s.collapsedShapeFrame(contentWidth: 258)
    check("studio: a long title widens the shape", long.width == 258 + 16 && long.minY == 0)

    // 14 inch MacBook Pro as the primary: 1512x982, 32pt menu bar, auxiliary areas leave a 185pt housing.
    let mbp = ScreenInfo(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
        auxiliaryTopRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32)
    )
    check("mbp: housing rect", mbp.hardwareNotch == CGRect(x: 663.5, y: 950, width: 185, height: 32))
    let m = NotchGeometry(screen: mbp)
    check("mbp: mode is below the menu bar", m.mode == .belowMenuBar && m.hasHardwareNotch)
    check("mbp: menu bar 32", m.menuBarHeight == 32)
    check("mbp: housing width 185", m.hardwareNotchWidth == 185)
    check("mbp: centered under the housing", m.centerX == 756 && m.panelFrame.midX == 756)
    check("mbp: panel top is the screen top", m.panelFrame.maxY == 982)
    check("mbp: panel x 356 y 722", m.panelFrame.origin == CGPoint(x: 356, y: 722))
    check("mbp: collapsed height 30", m.notchHeight == 30)
    check("mbp: card body at least the housing width plus the bleed", m.minimumWidth == 185 + 2 * NotchGeometry.housingBleed && NotchGeometry.housingBleed == 1)
    check("mbp: card top is the menu bar bottom", m.cardTop == 32)
    let under = m.collapsedShapeFrame(contentWidth: 100)
    check("mbp: the card starts at the menu bar bottom", under.minY == 32 && m.panelFrame.maxY - under.minY == mbp.visibleFrame.maxY)
    check("mbp: card body is the housing width plus the bleed", under.width - 2 * NotchGeometry.flare == 187 && under.height == 30)

    // Collapsed width under a hardware notch: the housing width, however long the title.
    let longTitle = Lanes.collapsedWidth(titleWidth: 400, minimum: m.minimumWidth)
    check("mbp: a long title wants more than the housing", longTitle == 400 + Lanes.collapsedChrome && longTitle > m.minimumWidth)
    check("mbp: a long title's collapsed width is the housing width plus the bleed", m.collapsedMaximumWidth == 187 && m.collapsedWidth(natural: longTitle) == 187)
    check("mbp: a short title keeps the housing width plus the bleed", m.collapsedWidth(natural: Lanes.collapsedWidth(titleWidth: 40, minimum: m.minimumWidth)) == 187)
    check("mbp: no title keeps the housing width plus the bleed", m.collapsedWidth(natural: Lanes.collapsedWidth(titleWidth: nil, minimum: m.minimumWidth)) == 187)
    check("studio: a long title still grows", s.collapsedMaximumWidth == nil && s.collapsedWidth(natural: Lanes.collapsedWidth(titleWidth: 400, minimum: s.minimumWidth)) == 400 + Lanes.collapsedChrome)
    check("studio: a short title keeps the 169 minimum", s.collapsedWidth(natural: Lanes.collapsedWidth(titleWidth: 40, minimum: s.minimumWidth)) == 169)

    // A wider housing wins over the 185pt floor.
    let wide = ScreenInfo(
        frame: mbp.frame, visibleFrame: mbp.visibleFrame, safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 656, height: 32),
        auxiliaryTopRight: CGRect(x: 856, y: 950, width: 656, height: 32)
    )
    check("wide housing: minimum width follows the housing plus the bleed", NotchGeometry(screen: wide).minimumWidth == 202)
    check("wide housing: the cap follows the housing plus the bleed", NotchGeometry(screen: wide).collapsedWidth(natural: 500) == 202)

    // Primary notch screen placed with an offset origin.
    let offset = ScreenInfo(
        frame: CGRect(x: 2560, y: 200, width: 1512, height: 982),
        visibleFrame: CGRect(x: 2560, y: 200, width: 1512, height: 950),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 2560, y: 1150, width: 663.5, height: 32),
        auxiliaryTopRight: CGRect(x: 3408.5, y: 1150, width: 663.5, height: 32)
    )
    let o = NotchGeometry(screen: offset)
    check("offset screen: centered under its housing", o.centerX == 3316)
    check("offset screen: panel top is that screen's top", o.panelFrame.maxY == 1182)
    check("offset screen: panel origin", o.panelFrame.origin == CGPoint(x: 2916, y: 922))
    check("offset screen: bridge over its housing plus the bleed", o.bridgeRect == CGRect(x: 3316 - 92.5 - 1 - 2916, y: 0, width: 187, height: 32))

    // Edge cases.
    let flat = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1000, height: 500), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 500))
    let f = NotchGeometry(screen: flat)
    check("no menu bar reported: assumes 30, in the menu bar", f.mode == .inMenuBar && f.notchHeight == 30 && f.panelFrame.maxY == 500)
    let noAux = ScreenInfo(frame: mbp.frame, visibleFrame: mbp.visibleFrame, safeAreaTop: 32)
    let n = NotchGeometry(screen: noAux)
    check("safe top without auxiliary areas: in the menu bar, screen center", n.mode == .inMenuBar && n.centerX == 756)
    check("safe top without auxiliary areas: menu bar height 32 as the notch height", n.notchHeight == 32 && n.panelFrame.maxY == 982)

    section("Screen choice")
    check("the primary wins even when another screen has a notch", NotchGeometry.chooseScreen([studio, mbp]) == 0)
    check("notch screen as primary", NotchGeometry.chooseScreen([mbp, studio]) == 0)
    check("one screen", NotchGeometry.chooseScreen([studio]) == 0)
    check("no screens: nil", NotchGeometry.chooseScreen([]) == nil)
    check("mode follows the chosen primary, not the other screen", NotchGeometry(screen: [studio, mbp][NotchGeometry.chooseScreen([studio, mbp])!]).mode == .inMenuBar)
}
