import CoreGraphics
import Foundation
import MainThingCore

/// Under a hardware notch: one shape from the screen top down, the menu bar row and the card at the card's own width.
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

        // Outlines as the view draws them: the card frame with its flare padding, below the menu bar
        // row. Collapsed, the card is the camera's width whatever the title.
        let f = NotchGeometry.flare
        let cameraCard = g.collapsedShapeFrame(contentWidth: g.collapsedWidth(natural: 420))
        let openCard = CGRect(x: cameraCard.minX - 200, y: g.cardTop, width: cameraCard.width + 400, height: 220)
        check("\(name): the collapsed card is the camera's width", cameraCard.width - 2 * f == bridge.width)
        // Full size cards are smooth everywhere; a card still growing out of the camera is too
        // short for its corners and only has to stay one shape.
        let cases: [(label: String, rect: CGRect, radius: CGFloat, openness: CGFloat, fullSize: Bool)] = [
            ("collapsed", cameraCard, 12, 0, true),
            ("open", openCard, 24, 1, true),
            ("half open, springing", CGRect(x: cameraCard.minX - 60, y: g.cardTop, width: cameraCard.width + 120, height: 100), 18, 0.5, true),
            ("empty, 0 tall", CGRect(x: cameraCard.minX, y: g.cardTop, width: cameraCard.width, height: 0), 12, 0, false),
            ("growing, 5 tall", CGRect(x: cameraCard.minX, y: g.cardTop, width: cameraCard.width, height: 5), 24, 0, false),
            ("growing, 5 tall, wide", CGRect(x: openCard.minX, y: g.cardTop, width: openCard.width, height: 5), 24, 1, false),
        ]
        for (label, rect, radius, openness, fullSize) in cases {
            let outline = NotchOutline.bridged(in: rect, bottomRadius: radius, bridgeHeight: bridge.height, openness: openness)
            let points = NotchOutline.samples(outline)
            let moves = outline.filter { if case .move = $0 { true } else { false } }.count
            let closes = outline.filter { $0 == .close }.count
            let sideLeft = rect.minX + f, sideRight = rect.maxX - f
            let flare = min(f * openness, bridge.height)
            check("\(name), \(label): one closed path", moves == 1 && closes == 1 && outline.last == .close && points.first == points.last)
            // The top edge is on the screen top and spans exactly the card's sides (plus the flares).
            let topRow = points.filter { $0.y == 0 }.map(\.x)
            check("\(name), \(label): the top edge is on the screen top, the card's sides plus the flares",
                  topRow.min() == sideLeft - flare && topRow.max() == sideRight + flare)
            check("\(name), \(label): nothing above the screen top", points.allSatisfy { $0.y >= -0.001 })
            // No step anywhere: below the flares the sides are the card's, straight through the menu bar's bottom edge.
            check("\(name), \(label): no step, the sides run straight through the menu bar's bottom edge",
                  points.filter { $0.y > flare + 0.001 && $0.y < min(rect.maxY - radius, g.cardTop + 8) - 0.001 }
                      .allSatisfy { $0.x == sideLeft || $0.x == sideRight })
            check("\(name), \(label): nothing below the card's bottom", points.allSatisfy { $0.y <= rect.maxY + 0.001 })
            if fullSize {
                check("\(name), \(label): smooth everywhere below the screen top", corners(outline, below: 0.5).isEmpty)
            }
        }

        // Collapsed at the camera width: a straight sided rect with rounded bottom, square top corners.
        let closed = NotchOutline.bridged(in: cameraCard, bottomRadius: 12, bridgeHeight: bridge.height)
        let closedPoints = NotchOutline.samples(closed)
        check("\(name), collapsed: the sides are the camera's sides",
              closedPoints.map(\.x).min() == bridge.minX && closedPoints.map(\.x).max() == bridge.maxX)
        check("\(name), collapsed: no flare, no curve but the bottom corners",
              !closed.contains { if case .quad = $0 { true } else { false } } && corners(closed, below: -1).count == 2)
        check("\(name), collapsed: the top edge is the camera's width on the screen top",
              closed.first == .move(CGPoint(x: bridge.minX, y: 0)) && closed.contains(.line(CGPoint(x: bridge.maxX, y: 0))))

        // Open: the card fills the menu bar row above it. The top edge is the screen top across the
        // card's full width, with the plain notch's concave flare at both top corners.
        let opened = NotchOutline.bridged(in: openCard, bottomRadius: 24, bridgeHeight: bridge.height, openness: 1)
        let openPoints = NotchOutline.samples(opened)
        check("\(name), open: concave flare at the top right corner",
              opened.contains(.quad(to: CGPoint(x: openCard.maxX - f, y: f), control: CGPoint(x: openCard.maxX - f, y: 0))))
        check("\(name), open: concave flare at the top left corner",
              opened.contains(.quad(to: CGPoint(x: openCard.minX, y: 0), control: CGPoint(x: openCard.minX + f, y: 0))))
        check("\(name), open: the sides are the card's, straight from the flare to the bottom",
              openPoints.map(\.x).min() == openCard.minX && openPoints.filter { $0.y > f && $0.y < openCard.maxY - 24 }.allSatisfy { $0.x == openCard.minX + f || $0.x == openCard.maxX - f })
        // The morph: for any openness and any card width from the camera's to an open one, the top
        // row is exactly the card's width plus the flares, so the top edge and the card's sides
        // move as one whatever the two springs are doing.
        var matches = true
        for w in stride(from: cameraCard.width, through: openCard.width, by: 25) {
            for i in 0...20 {
                let o = CGFloat(i) / 20
                let rect = CGRect(x: (NotchGeometry.panelSize.width - w) / 2, y: g.cardTop, width: w, height: 120)
                let xs = NotchOutline.samples(NotchOutline.bridged(in: rect, bottomRadius: 18, bridgeHeight: bridge.height, openness: o))
                    .filter { $0.y == 0 }.map(\.x)
                if abs((xs.max() ?? 0) - (xs.min() ?? 0) - ((w - 2 * f) + 2 * f * o)) > 1e-9 { matches = false }
            }
        }
        check("\(name), morph: at any openness and card width the top row is the card's width plus the flares", matches)

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
    }

    section("Outline corners")
    let square: [OutlineSegment] = [.move(.zero), .line(CGPoint(x: 10, y: 0)), .line(CGPoint(x: 10, y: 10)), .line(CGPoint(x: 0, y: 10)), .close]
    check("the corner finder finds a square's four corners", corners(square, below: -1).count == 4)

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
/// only corners are meant to be the two on the screen top.
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
