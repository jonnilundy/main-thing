import CoreGraphics
import Foundation
import MainThingCore

/// Under a hardware notch: one shape from the screen top, the bridge under the camera joined to the card.
@MainActor
func runBridgeChecks() {
    // Both MacBook Pro sizes, with the housing the 14 inch fixture measures: 185pt wide, 32pt tall
    // (the menu bar row).
    let fixtures: [(name: String, screen: ScreenInfo)] = [
        ("14 inch", ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaTop: 32,
            auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
            auxiliaryTopRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32)
        )),
        ("16 inch", ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085),
            safeAreaTop: 32,
            auxiliaryTopLeft: CGRect(x: 0, y: 1085, width: 771.5, height: 32),
            auxiliaryTopRight: CGRect(x: 956.5, y: 1085, width: 771.5, height: 32)
        )),
    ]

    for (name, screen) in fixtures {
        section("Bridge, \(name)")
        let g = NotchGeometry(screen: screen)
        guard let bridge = g.bridgeRect, let housing = screen.hardwareNotch,
              let auxLeft = screen.auxiliaryTopLeft, let auxRight = screen.auxiliaryTopRight else {
            check("\(name): has a bridge", false)
            continue
        }
        check("\(name): panel top is the screen top", g.panelFrame.maxY == screen.frame.maxY)
        check("\(name): bridge left edge is the left auxiliary area's right edge", g.panelFrame.minX + bridge.minX == auxLeft.maxX)
        check("\(name): bridge right edge is the right auxiliary area's left edge", g.panelFrame.minX + bridge.maxX == auxRight.minX)
        check("\(name): bridge is the housing width", bridge.width == housing.width && bridge.width == 185)
        check("\(name): bridge from the screen top to the menu bar bottom",
              bridge.minY == 0 && bridge.height == screen.frame.maxY - screen.visibleFrame.maxY && bridge.height == 32)
        check("\(name): the card starts where the bridge ends", g.cardTop == bridge.maxY)
        check("\(name): bridge centered in the panel", g.bridgeOffset == 0 && bridge.midX == g.panelFrame.width / 2)
        let camera = NotchHover.panelPoint(screenPoint: CGPoint(x: housing.midX, y: screen.frame.maxY - 10), panelFrame: g.panelFrame)
        check("\(name): the camera's center is on the bridge", bridge.contains(camera))

        // The empty rule.
        check("\(name): an empty list draws nothing collapsed", !g.drawsCollapsed(taskCount: 0))
        check("\(name): a task draws the card", g.drawsCollapsed(taskCount: 1) && g.drawsCollapsed(taskCount: 5))

        // Outlines as the view draws them: the card frame with its flare padding, below the bridge.
        let shortCard = g.collapsedShapeFrame(contentWidth: 60)
        let longCard = g.collapsedShapeFrame(contentWidth: 420)
        let openCard = CGRect(x: longCard.minX - 40, y: g.cardTop, width: longCard.width + 80, height: 220)
        // Full size cards are smooth everywhere; a card still growing out of the camera is too
        // short for its corners and only has to stay one shape.
        let cases: [(label: String, rect: CGRect, radius: CGFloat, fullSize: Bool)] = [
            ("collapsed, short title", shortCard, 12, true),
            ("collapsed, long title", longCard, 12, true),
            ("open", openCard, 24, true),
            ("empty, 0 tall", CGRect(x: shortCard.minX, y: g.cardTop, width: shortCard.width, height: 0), 12, false),
            ("growing, 5 tall", CGRect(x: longCard.minX, y: g.cardTop, width: longCard.width, height: 5), 24, false),
        ]
        for (label, rect, radius, fullSize) in cases {
            let outline = NotchOutline.bridged(
                in: rect, bottomRadius: radius, bridgeWidth: bridge.width, bridgeHeight: bridge.height,
                bridgeOffset: bridge.midX - rect.midX
            )
            let points = NotchOutline.samples(outline)
            let moves = outline.filter { if case .move = $0 { true } else { false } }.count
            let closes = outline.filter { $0 == .close }.count
            check("\(name), \(label): one closed path", moves == 1 && closes == 1 && outline.last == .close && points.first == points.last)
            check("\(name), \(label): starts on the screen top at the bridge's left edge", points.first == CGPoint(x: bridge.minX, y: 0))
            // Nothing of ours in the menu bar row outside the camera notch's width.
            let row = points.filter { $0.y < g.cardTop - 0.001 }
            check("\(name), \(label): in the menu bar row only the bridge",
                  row.allSatisfy { $0.x >= bridge.minX - 0.001 && $0.x <= bridge.maxX + 0.001 })
            // The bridge reaches the card: both of its sides run down to the card's top edge.
            check("\(name), \(label): bridge sides reach the card top",
                  outline.contains(.line(CGPoint(x: bridge.maxX, y: g.cardTop))) && points.contains(CGPoint(x: bridge.minX, y: g.cardTop)))
            check("\(name), \(label): nothing below the card's bottom", points.allSatisfy { $0.y <= rect.maxY + 0.001 })
            if fullSize {
                check("\(name), \(label): smooth everywhere below the screen top", corners(outline, below: 0.5).isEmpty)
            }
        }

        // Open: the card fills the menu bar row above it. The top edge is the screen top across the
        // card's full width, with the plain notch's concave flare at both top corners.
        let f = NotchGeometry.flare
        let opened = NotchOutline.bridged(
            in: openCard, bottomRadius: 24, bridgeWidth: bridge.width, bridgeHeight: bridge.height,
            bridgeOffset: bridge.midX - openCard.midX, openness: 1
        )
        let openPoints = NotchOutline.samples(opened)
        let openTop = openPoints.filter { $0.y == 0 }.map(\.x)
        check("\(name), open: one closed path", opened.filter { $0 == .close }.count == 1 && openPoints.first == openPoints.last)
        check("\(name), open: the top edge is the screen top, the card's full width", openTop.min() == openCard.minX && openTop.max() == openCard.maxX)
        check("\(name), open: concave flare at the top right corner",
              opened.contains(.quad(to: CGPoint(x: openCard.maxX - f, y: f), control: CGPoint(x: openCard.maxX - f, y: 0))))
        check("\(name), open: concave flare at the top left corner",
              opened.contains(.quad(to: CGPoint(x: openCard.minX, y: 0), control: CGPoint(x: openCard.minX + f, y: 0))))
        check("\(name), open: the sides are the card's, straight from the flare to the bottom",
              openPoints.map(\.x).min() == openCard.minX && openPoints.filter { $0.y > f && $0.y < openCard.maxY - 24 }.allSatisfy { $0.x == openCard.minX + f || $0.x == openCard.maxX - f })
        check("\(name), open: no join at the menu bar's bottom edge, the sides run straight through",
              !openPoints.contains { $0.y > f + 0.001 && $0.y < g.cardTop + 0.001 && $0.x != openCard.minX + f && $0.x != openCard.maxX - f })
        check("\(name), open: nothing below the card's bottom, smooth below the screen top",
              openPoints.allSatisfy { $0.y <= openCard.maxY + 0.001 } && corners(opened, below: 0.5).isEmpty)
        // The morph: the top row widens from the camera to the card without a jump.
        var lastWidth: CGFloat = 0, widening = true
        for i in 0...20 {
            let o = NotchOutline.bridged(
                in: openCard, bottomRadius: 24, bridgeWidth: bridge.width, bridgeHeight: bridge.height,
                bridgeOffset: bridge.midX - openCard.midX, openness: CGFloat(i) / 20
            )
            let xs = NotchOutline.samples(o).filter { $0.y == 0 }.map(\.x)
            let w = (xs.max() ?? 0) - (xs.min() ?? 0)
            if i == 0 { check("\(name), morph: closed the top row is the camera's width", w == bridge.width) }
            if i > 0, w < lastWidth - 0.001 || w - lastWidth > 20 { widening = false }
            lastWidth = w
        }
        check("\(name), morph: the top row only widens, in small steps", widening && abs(lastWidth - openCard.width) < 0.001)

        // The pointer: open, the menu bar row part of the card is inside; beside the card it is not.
        let shapeRect = CGRect(x: openCard.minX, y: g.cardTop, width: openCard.width, height: openCard.height)
        let rowLeft = CGPoint(x: shapeRect.minX + 20, y: 10), rowOutside = CGPoint(x: shapeRect.minX - 3, y: 10)
        let cameraPoint = CGPoint(x: bridge.midX, y: 10)
        check("\(name), hover: open, the menu bar row inside the card's width is inside",
              NotchHover.inside(rowLeft, shape: shapeRect, bridge: bridge, isOpen: true) && NotchHover.inside(CGPoint(x: shapeRect.maxX - 1, y: 0), shape: shapeRect, bridge: bridge, isOpen: true))
        check("\(name), hover: open, the menu bar row beside the card stays click through",
              !NotchHover.inside(rowOutside, shape: shapeRect, bridge: bridge, isOpen: true))
        check("\(name), hover: collapsed, only the camera's width is inside",
              NotchHover.inside(cameraPoint, shape: shapeRect, bridge: bridge, isOpen: false) && !NotchHover.inside(rowLeft, shape: shapeRect, bridge: bridge, isOpen: false))
        check("\(name), hover: open, the card below is still inside", NotchHover.inside(CGPoint(x: shapeRect.midX, y: shapeRect.midY), shape: shapeRect, bridge: bridge, isOpen: true))

        // The narrowest card continues the notch's sides straight down: no join at all.
        let straight = NotchOutline.bridged(in: shortCard, bottomRadius: 12, bridgeWidth: bridge.width, bridgeHeight: bridge.height,
                                            bridgeOffset: bridge.midX - shortCard.midX)
        check("\(name): short title card is the notch's width", shortCard.width - 2 * NotchGeometry.flare == bridge.width)
        check("\(name): short title card has straight sides, no flare", !straight.contains { if case .quad = $0 { true } else { false } })

        // A long title: the join flares out from the notch's width to the card's.
        let wide = NotchOutline.bridged(in: longCard, bottomRadius: 12, bridgeWidth: bridge.width, bridgeHeight: bridge.height,
                                        bridgeOffset: bridge.midX - longCard.midX)
        let top = g.cardTop, r = NotchOutline.joinRadius, d = NotchOutline.joinDrop
        check("\(name): long title, concave flare off the bridge's right side",
              wide.contains(.quad(to: CGPoint(x: bridge.maxX + r, y: top + d), control: CGPoint(x: bridge.maxX, y: top + d))))
        check("\(name): long title, rounded shoulder into the card's right side",
              wide.contains(.quad(to: CGPoint(x: longCard.maxX - NotchGeometry.flare, y: top + d + r),
                                  control: CGPoint(x: longCard.maxX - NotchGeometry.flare, y: top + d))))
        check("\(name): long title, flare back into the bridge's left side",
              wide.contains(.quad(to: CGPoint(x: bridge.minX, y: top), control: CGPoint(x: bridge.minX, y: top + d))))
        let widest = NotchOutline.samples(wide).map(\.x)
        check("\(name): long title, the card is its own width",
              widest.min() == longCard.minX + NotchGeometry.flare && widest.max() == longCard.maxX - NotchGeometry.flare)
    }

    section("Join")
    let square: [OutlineSegment] = [.move(.zero), .line(CGPoint(x: 10, y: 0)), .line(CGPoint(x: 10, y: 10)), .line(CGPoint(x: 0, y: 10)), .close]
    check("the corner finder finds a square's four corners", corners(square, below: -1).count == 4)
    check("no step, no join", NotchOutline.join(step: 0) == (0, 0, 0) && NotchOutline.join(step: -3) == (0, 0, 0))
    let full = NotchOutline.join(step: 100)
    check("a big step: full flare, drop and shoulder", full == (NotchOutline.joinRadius, NotchOutline.joinDrop, NotchOutline.joinRadius))
    check("the drop leaves the title its room: under 5pt", NotchOutline.joinDrop < 5)
    // As the card widens a quarter point at a time, the join never jumps.
    var smooth = true, growing = true
    var last = NotchOutline.join(step: 0)
    for i in 1...160 {
        let next = NotchOutline.join(step: CGFloat(i) * 0.25)
        if abs(next.flare - last.flare) > 0.125 + 1e-9 || abs(next.drop - last.drop) > 0.125 + 1e-9 || abs(next.shoulder - last.shoulder) > 0.125 + 1e-9 { smooth = false }
        if next.flare < last.flare || next.drop < last.drop { growing = false }
        last = next
    }
    check("the join grows without a jump as the card widens", smooth && growing)
    check("flare and shoulder fit the step", (1...80).allSatisfy { let s = CGFloat($0) / 2, j = NotchOutline.join(step: s); return j.flare + j.shoulder <= s + 1e-9 })

    section("Bridge hit test")
    let g = NotchGeometry(screen: fixtures[0].screen)
    let bridge = g.bridgeRect!
    let card = CGRect(x: 250, y: g.cardTop, width: 300, height: 30)
    check("the camera opens the card, even with nothing drawn", NotchHover.inside(CGPoint(x: bridge.midX, y: 10), shape: .zero, bridge: bridge, isOpen: false))
    check("the camera stays inside while open", NotchHover.inside(CGPoint(x: bridge.midX, y: 2), shape: card, bridge: bridge, isOpen: true))
    check("the card is inside", NotchHover.inside(CGPoint(x: 270, y: g.cardTop + 10), shape: card, bridge: bridge, isOpen: false))
    check("menu bar beside the camera is click through, collapsed", !NotchHover.inside(CGPoint(x: 270, y: g.cardTop - 2), shape: card, bridge: bridge, isOpen: false))
    check("menu bar above the open card is inside: the card fills it",
          NotchHover.inside(CGPoint(x: 270, y: g.cardTop - 4), shape: card, bridge: bridge, isOpen: true))
    check("menu bar beside the open card is click through (no slack above the card)",
          !NotchHover.inside(CGPoint(x: 246, y: g.cardTop - 4), shape: card, bridge: bridge, isOpen: true))
    check("the open slack still reaches past the card's sides", NotchHover.inside(CGPoint(x: 246, y: g.cardTop + 10), shape: card, bridge: bridge, isOpen: true))
    check("far off the shape is click through", !NotchHover.inside(CGPoint(x: 20, y: 10), shape: card, bridge: bridge, isOpen: true))
    check("no bridge: the plain rule, slack above the card", NotchHover.inside(CGPoint(x: 270, y: -4), shape: CGRect(x: 250, y: 0, width: 300, height: 30), bridge: nil, isOpen: true))

    section("Bridged card map")
    let bridged = CardMap(notchHeight: 30, taskCount: 3, bridged: true)
    let plain = CardMap(notchHeight: 30, taskCount: 3)
    check("on the bridge no slot lights, a click crosses nothing off", bridged.slot(atY: -5) == .none && bridged.slot(atY: -30) == .none)
    check("on the band: task 1, bridged or not", bridged.slot(atY: 5) == .task(0) && plain.slot(atY: 5) == .task(0))
    check("unbridged: above the card is still task 1", plain.slot(atY: -5) == .task(0))
}

/// Joints in an outline below `y` where the direction turns by more than 1 degree: the outline's
/// only corners are meant to be the bridge's two on the screen top.
private func corners(_ outline: [OutlineSegment], below y: CGFloat) -> [CGPoint] {
    var pieces: [(start: CGPoint, end: CGPoint, inDir: CGVector, outDir: CGVector)] = []
    var current = CGPoint.zero, start = CGPoint.zero
    func add(_ a: CGPoint, _ b: CGPoint, _ i: CGVector, _ o: CGVector) {
        if hypot(b.x - a.x, b.y - a.y) > 1e-6 { pieces.append((a, b, i, o)) }
    }
    for segment in outline {
        switch segment {
        case .move(let p): current = p; start = p
        case .line(let p):
            let v = CGVector(dx: p.x - current.x, dy: p.y - current.y)
            add(current, p, v, v); current = p
        case .quad(let to, let control):
            add(current, to, CGVector(dx: control.x - current.x, dy: control.y - current.y), CGVector(dx: to.x - control.x, dy: to.y - control.y))
            current = to
        case .arc(let center, let radius, let from, let to):
            guard radius > 1e-6 else { continue }
            let sign: CGFloat = to > from ? 1 : -1
            func tangent(_ deg: Double) -> CGVector {
                let a = deg * .pi / 180
                return CGVector(dx: -sin(a) * sign, dy: cos(a) * sign)
            }
            let end = CGPoint(x: center.x + radius * cos(to * .pi / 180), y: center.y + radius * sin(to * .pi / 180))
            add(current, end, tangent(from), tangent(to)); current = end
        case .close:
            let v = CGVector(dx: start.x - current.x, dy: start.y - current.y)
            add(current, start, v, v); current = start
        }
    }
    var found: [CGPoint] = []
    for i in pieces.indices {
        let a = pieces[i], b = pieces[(i + 1) % pieces.count]
        guard a.end.y > y else { continue }
        let cross = a.outDir.dx * b.inDir.dy - a.outDir.dy * b.inDir.dx
        let dot = a.outDir.dx * b.inDir.dx + a.outDir.dy * b.inDir.dy
        if abs(atan2(cross, dot)) > .pi / 180 { found.append(a.end) }
    }
    return found
}
