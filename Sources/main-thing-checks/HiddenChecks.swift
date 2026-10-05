import CoreGraphics
import Foundation
import MainThingCore

/// Hide: the closed notch folds into the menu bar row and keeps only the dot.
@MainActor
func runHiddenChecks() {
    let mbp = ScreenInfo(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
        auxiliaryTopRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32)
    )
    let studio = ScreenInfo(
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410)
    )
    let f = NotchGeometry.flare
    let wing = NotchGeometry.hiddenWing

    section("Hidden, under a hardware notch")
    let m = NotchGeometry(screen: mbp)
    let bridge = m.bridgeRect!
    let rect = m.hiddenRect
    check("hidden: the housing width plus the bleed and an equal wing on each side", m.hiddenWidth == 185 + 2 * NotchGeometry.housingBleed + 2 * wing && wing == 30)
    check("hidden: the wings are equal",
          bridge.minX - rect.minX == wing && rect.maxX - bridge.maxX == wing && rect.midX == bridge.midX)
    check("hidden: the menu bar row only, as tall as the bridge", rect.minY == 0 && rect.height == m.hiddenHeight && rect.height == 32 && rect.height == bridge.height)
    check("hidden: the dot is centered in the left wing", m.hiddenDotX == wing / 2 && rect.minX + m.hiddenDotX == bridge.minX - wing / 2)
    check("hidden: the dot clears the camera and the edge by the same room",
          m.hiddenDotX - 3.5 == wing - m.hiddenDotX - 3.5)
    check("hidden: a wider housing keeps the wings",
          NotchGeometry(screen: ScreenInfo(
              frame: mbp.frame, visibleFrame: mbp.visibleFrame, safeAreaTop: 32,
              auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 656, height: 32),
              auxiliaryTopRight: CGRect(x: 856, y: 950, width: 656, height: 32)
          )).hiddenWidth == 200 + 2 * NotchGeometry.housingBleed + 2 * wing)

    // Hover: the hidden shape is the bridge of the hover test, the shape under it is empty.
    let hover = m.hoverBridge(hidden: true)
    let none = CGRect(x: rect.minX, y: m.cardTop, width: rect.width, height: 0)
    check("hover: hidden, the bridge is the whole hidden shape", hover == rect)
    check("hover: shown, the bridge is the camera's", m.hoverBridge(hidden: false) == bridge)
    func inside(_ p: CGPoint) -> Bool { NotchHover.inside(p, shape: none, bridge: hover, isOpen: false) }
    check("hover: hidden, the left wing, the camera and the right wing open the list",
          inside(CGPoint(x: rect.minX + 4, y: 10)) && inside(CGPoint(x: rect.midX, y: 10)) && inside(CGPoint(x: rect.maxX - 4, y: 10)))
    check("hover: hidden, the dot is inside", inside(CGPoint(x: rect.minX + m.hiddenDotX, y: rect.midY)))
    check("hover: hidden, the menu bar beside the shape is click through",
          !inside(CGPoint(x: rect.minX - 3, y: 10)) && !inside(CGPoint(x: rect.maxX + 3, y: 10)))
    check("hover: hidden, nothing below the menu bar row", !inside(CGPoint(x: rect.midX, y: rect.height + 2)))
    check("hover: shown, the wing is click through again",
          !NotchHover.inside(CGPoint(x: rect.minX + 4, y: 10), shape: CGRect(x: 250, y: m.cardTop, width: 300, height: 30), bridge: m.hoverBridge(hidden: false), isOpen: false))

    // Opened from hidden: the normal open card. The hover test gives the same answer with the
    // hidden bridge as with the camera's, over the whole panel.
    let openCard = CGRect(x: 242, y: m.cardTop, width: 316, height: 190)
    var same = true
    for x in stride(from: CGFloat(0), through: 800, by: 4) {
        for y in stride(from: CGFloat(-4), through: 260, by: 4) {
            let p = CGPoint(x: x, y: y)
            if NotchHover.inside(p, shape: openCard, bridge: hover, isOpen: true) != NotchHover.inside(p, shape: openCard, bridge: bridge, isOpen: true) { same = false }
        }
    }
    check("open from hidden: the open card is hit as it always is", same)
    check("open from hidden: the open card is wider than the hidden shape", openCard.width >= OpenLayout.minimumWidth && openCard.width > m.hiddenWidth)
    check("open from hidden: the card size does not depend on hiding",
          m.collapsedShapeFrame(contentWidth: 100).width == 185 + 2 * NotchGeometry.housingBleed + 2 * f && OpenLayout.width(bandWidth: 200, rowTitleWidths: [100], screenWidth: 1512) == 300)

    // The outline: the card is the whole row (bridge height 0), flares out, rounded bottom.
    section("Hidden outline")
    let width = m.hiddenWidth + 2 * f
    let row = CGRect(x: (NotchGeometry.panelSize.width - width) / 2, y: 0, width: width, height: m.hiddenHeight)
    let folded = NotchOutline.bridged(in: row, bottomRadius: 12, bridgeHeight: 0, openness: 1)
    let points = NotchOutline.samples(folded)
    let top = points.filter { $0.y == 0 }.map(\.x)
    check("outline: one closed path", folded.filter { $0 == .close }.count == 1 && points.first == points.last)
    check("outline: the top edge is the screen top, the shape's width plus the flares",
          top.min() == row.minX && top.max() == row.maxX)
    check("outline: the sides are the shape's, straight down to the bottom corners",
          points.filter { $0.y > f && $0.y < row.maxY - 12 }.allSatisfy { $0.x == row.minX + f || $0.x == row.maxX - f })
    check("outline: rounded bottom corners, concave top flares",
          folded.filter { if case .arc = $0 { true } else { false } }.count == 2 && folded.filter { if case .quad = $0 { true } else { false } }.count == 2)
    check("outline: nothing above the screen top or below the row", points.allSatisfy { $0.y >= -0.001 && $0.y <= row.maxY + 0.001 })
    // The plain notch's outline: the same flare, a quarter curve with its control on the corner.
    check("outline: the flare is the plain notch's",
          folded.contains(.quad(to: CGPoint(x: row.maxX - f, y: f), control: CGPoint(x: row.maxX - f, y: 0))))

    // The morph from hidden to the collapsed bridge and the card, as the view drives it: the
    // bridge grows from 0 to the menu bar row while the card's top moves down with it.
    var stays = true
    for i in 0...20 {
        let t = CGFloat(i) / 20
        let bh = bridge.height * t
        let w = m.hiddenWidth + (m.minimumWidth - m.hiddenWidth) * t + 2 * f
        let card = CGRect(x: (NotchGeometry.panelSize.width - w) / 2, y: bh, width: w, height: (m.hiddenHeight - bh) + 30 * t)
        let outline = NotchOutline.bridged(in: card, bottomRadius: 12, bridgeHeight: bh, openness: 1 - t)
        let samples = NotchOutline.samples(outline)
        let flare = f * (1 - t)
        let topRow = samples.filter { $0.y == 0 }.map(\.x)
        if outline.filter({ $0 == .close }).count != 1 || samples.contains(where: { $0.y < -0.001 || $0.y > card.maxY + 0.001 })
            || abs((topRow.max() ?? 0) - (topRow.min() ?? 0) - (w - 2 * f + 2 * flare)) > 1e-9 { stays = false }
    }
    check("morph: hidden to shown stays one shape on the screen top, the top row the card's width plus the flares", stays)

    // An empty list under a hardware notch: the Hide shape without the wings and the dot. The
    // camera's drawn width, the menu bar row tall, the Hide shape's bottom radius, the same flares.
    section("Empty list under a hardware notch")
    let emptyRadius = NotchGeometry.closedBottomRadius
    let emptyWidth = m.emptyWidth + 2 * f
    let emptyRow = CGRect(x: (NotchGeometry.panelSize.width - emptyWidth) / 2, y: 0, width: emptyWidth, height: m.hiddenHeight)
    let emptyOutline = NotchOutline.bridged(in: emptyRow, bottomRadius: emptyRadius, bridgeHeight: 0, openness: 1)
    let emptyPoints = NotchOutline.samples(emptyOutline)
    check("empty: the drawn housing wide, the menu bar row tall, centered on the camera",
          m.emptyWidth == m.drawnHousingWidth && m.emptyWidth == bridge.width && m.hiddenHeight == bridge.height
              && emptyRow.midX == bridge.midX && emptyRow.minX + f == bridge.minX)
    check("empty: it draws no card and is not the Hide shape", !m.drawsCollapsed(taskCount: 0) && m.emptyWidth < m.hiddenWidth)
    check("empty: the Hide shape's bottom radius, 12", emptyRadius == 12 && emptyRadius == NotchGeometry.closedBottomRadius)
    check("empty: the bottom corners are rounded, the outline is not a plain rect",
          emptyOutline.filter { if case .arc(_, let r, _, _) = $0 { r == emptyRadius } else { false } }.count == 2
              && !emptyPoints.contains(CGPoint(x: emptyRow.minX + f, y: emptyRow.maxY))
              && !emptyPoints.contains(CGPoint(x: emptyRow.maxX - f, y: emptyRow.maxY))
              && emptyPoints.contains(CGPoint(x: emptyRow.minX + f + emptyRadius, y: emptyRow.maxY)))
    check("empty: the same concave top flares as Hide, on the screen top",
          emptyOutline.filter { if case .quad = $0 { true } else { false } }.count == 2
              && emptyOutline.contains(.quad(to: CGPoint(x: emptyRow.maxX - f, y: f), control: CGPoint(x: emptyRow.maxX - f, y: 0)))
              && emptyPoints.filter { $0.y == 0 }.map(\.x).min() == emptyRow.minX)
    check("empty: one closed path inside its row", emptyOutline.filter { $0 == .close }.count == 1
              && emptyPoints.allSatisfy { $0.y >= -0.001 && $0.y <= emptyRow.maxY + 0.001 })
    check("empty: no wider than the camera's black plus the flares", emptyPoints.allSatisfy { $0.x >= bridge.minX - f - 0.001 && $0.x <= bridge.maxX + f + 0.001 })
    check("empty: hovering it opens the card, the camera is the bridge", NotchHover.inside(CGPoint(x: bridge.midX, y: 10), shape: none, bridge: m.hoverBridge(hidden: false), isOpen: false))

    // The morph from the empty shape to the first task's collapsed card, and back, as the view
    // drives it: the bridge grows from 0 to the menu bar row, the flares shrink, the card's top
    // moves down and its bottom falls to the collapsed band.
    var emptyMorph = true
    var lastBottom: CGFloat = -1
    for i in 0...20 {
        let t = CGFloat(i) / 20
        let bh = bridge.height * t
        let w = m.emptyWidth + (m.minimumWidth - m.emptyWidth) * t + 2 * f
        let bottom = m.hiddenHeight + m.notchHeight * t
        let card = CGRect(x: (NotchGeometry.panelSize.width - w) / 2, y: bh, width: w, height: bottom - bh)
        let outline = NotchOutline.bridged(in: card, bottomRadius: emptyRadius, bridgeHeight: bh, openness: 1 - t)
        let samples = NotchOutline.samples(outline)
        if outline.filter({ $0 == .close }).count != 1 || samples.contains(where: { $0.y < -0.001 || $0.y > card.maxY + 0.001 })
            || (samples.map(\.y).max() ?? 0) < lastBottom { emptyMorph = false }
        lastBottom = samples.map(\.y).max() ?? 0
    }
    check("empty: morphing to the first task's card stays one shape on the screen top, the bottom only falls", emptyMorph)

    section("Hidden, no hardware notch")
    let s = NotchGeometry(screen: studio)
    let pill = s.hiddenRect
    check("hidden: the minimal width is a named constant a deliberate pill wide",
          s.hiddenWidth == NotchGeometry.hiddenWidthInMenuBar && s.hiddenWidth >= 64 && s.hiddenWidth <= 90 && s.hiddenWidth < NotchGeometry.housingWidth)
    check("hidden: the menu bar row tall, centered on the screen", s.hiddenHeight == 30 && pill.midX == NotchGeometry.panelSize.width / 2 && s.panelFrame.midX == studio.frame.midX)
    check("hidden: the dot is in the center", s.hiddenDotX == s.hiddenWidth / 2 && pill.minX + s.hiddenDotX == pill.midX)
    check("hidden: no bridge, the shape's own rect is the test", s.hoverBridge(hidden: true) == nil && s.hoverBridge(hidden: false) == nil)
    let shape = CGRect(x: pill.minX - f, y: 0, width: pill.width + 2 * f, height: pill.height)
    check("hover: hidden, the pill opens the list, beside it is click through",
          NotchHover.inside(CGPoint(x: pill.midX, y: 10), shape: shape, bridge: nil, isOpen: false)
              && !NotchHover.inside(CGPoint(x: shape.minX - 3, y: 10), shape: shape, bridge: nil, isOpen: false))
    check("hidden: an empty list still draws the plain shape", s.drawsCollapsed(taskCount: 0))

    // The black shape never fades. Under a hardware notch a translucent card shows the camera and
    // the app behind it (seen on an M5 MacBook Pro), so only its geometry may animate. The rule is
    // in the source: no opacity or transition between the black fill and the end of the card's
    // modifiers, and no panel alpha outside the invisible test panels.
    section("Opaque shape")
    let app = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources").appendingPathComponent("MainThingApp")
    func source(_ name: String) -> String { (try? String(contentsOf: app.appendingPathComponent(name + ".swift"), encoding: .utf8)) ?? "" }
    let view = source("NotchView")
    if let start = view.range(of: ".background(shape.fill(.black))"),
       let end = view.range(of: ".contextMenu { NotchMenu", range: start.upperBound..<view.endIndex) {
        let chain = view[start.lowerBound..<end.lowerBound]
        check("opaque shape: no opacity on the shape or its container", !chain.contains(".opacity("))
        check("opaque shape: no transition on the shape or its container", !chain.contains(".transition("))
    } else {
        check("opaque shape: the black fill and the card's modifiers are found in NotchView.swift", false)
    }
    let withAlpha = ["NotchPanel", "HoverController", "CardController", "AppDelegate", "PanelLayout", "NotchView", "NotchModel"].filter { source($0).contains("alphaValue") }
    check("opaque shape: the panel never sets an alpha (only the invisible test panels do)", withAlpha.isEmpty && !source("NotchPanel").isEmpty)
}
