import CoreGraphics
import Foundation
import MainThingCore

@MainActor
func runHoverChecks() {
    section("NotchHover")
    let shape = CGRect(x: 300, y: 0, width: 200, height: 30)
    check("collapsed: point in shape is inside", NotchHover.inside(CGPoint(x: 400, y: 15), shape: shape, isOpen: false))
    check("collapsed: top edge counts", NotchHover.inside(CGPoint(x: 400, y: 0), shape: shape, isOpen: false))
    check("collapsed: 4pt below the shape is outside", !NotchHover.inside(CGPoint(x: 400, y: 34), shape: shape, isOpen: false))
    check("collapsed: 4pt beside the shape is outside", !NotchHover.inside(CGPoint(x: 296, y: 15), shape: shape, isOpen: false))
    let open = CGRect(x: 190, y: 0, width: 420, height: 160)
    check("open: 7pt below the shape is still inside", NotchHover.inside(CGPoint(x: 400, y: 167), shape: open, isOpen: true))
    check("open: 9pt below the shape is outside", !NotchHover.inside(CGPoint(x: 400, y: 169), shape: open, isOpen: true))
    check("open: 7pt left of the shape is still inside", NotchHover.inside(CGPoint(x: 183, y: 50), shape: open, isOpen: true))
    check("open: 9pt right of the shape is outside", !NotchHover.inside(CGPoint(x: 619, y: 50), shape: open, isOpen: true))
    check("empty shape is never inside", !NotchHover.inside(.zero, shape: .zero, isOpen: false))

    check("collapsed, cursor enters: open at once", NotchHover.intent(isOpen: false, inside: true) == .open)
    check("collapsed, outside: nothing", NotchHover.intent(isOpen: false, inside: false) == .none)
    check("open, inside: nothing", NotchHover.intent(isOpen: true, inside: true) == .none)
    check("open, cursor leaves: close", NotchHover.intent(isOpen: true, inside: false) == .close)
    check("slack is 8pt", NotchHover.slack == 8)

    // AppKit screen points on a 1440pt tall screen, panel 800x240 at the top center.
    let panel = CGRect(x: 880, y: 1200, width: 800, height: 240)
    check("panel point: 10pt under the screen top at center is (400, 10)",
          NotchHover.panelPoint(screenPoint: CGPoint(x: 1280, y: 1430), panelFrame: panel) == CGPoint(x: 400, y: 10))
    check("panel point: the panel's top left is (0, 0)",
          NotchHover.panelPoint(screenPoint: CGPoint(x: 880, y: 1440), panelFrame: panel) == .zero)

    section("RowHaptics")
    do {
        var h = RowHaptics()
        check("entering a row ticks", h.enter("B#0", at: 10) == true)
        check("moving within the row is silent", h.enter("B#0", at: 10.1) == false && h.enter("B#0", at: 11) == false)
        check("the next row ticks", h.enter("C#0", at: 10.2) == true)
        h.exit("C#0")
        check("leaving and coming back ticks again", h.enter("C#0", at: 10.5) == true)
        h.exit("B#0")
        check("an exit of another row keeps the current one", h.enter("C#0", at: 10.6) == false)
        h.listAnimates(at: 20)
        check("a row arriving under a still cursor while the list moves is silent", h.enter("D#0", at: 20.1) == false)
        check("and the row is remembered, so settling on it does not tick late", h.enter("D#0", at: 20.5) == false)
        check("after 300ms entries tick again", h.enter("E#0", at: 20.3) == true)
        check("settle is 300ms", RowHaptics.settle == 0.3)
    }
    do {
        // Task 1's pill in the band is a row target like rows 2..N: key "A#0", then "B#0" below it.
        var h = RowHaptics()
        check("entering the band row ticks", h.enter("A#0", at: 30) == true)
        check("moving along the band row, off the letters, is silent", h.enter("A#0", at: 30.2) == false)
        check("from the band row to row 2 ticks", h.enter("B#0", at: 30.4) == true)
        h.exit("B#0")
        check("from row 2 back to the band row ticks", h.enter("A#0", at: 30.6) == true)
        h.listAnimates(at: 31)
        h.exit("A#0")
        check("task 1 crossed off: the next task moving up under a still cursor is silent", h.enter("B#0", at: 31.1) == false)
    }

    section("Band row hit test")
    do {
        // A 316 wide open card below a 30pt hardware notch band: title at 46, count at the right.
        let band = CGSize(width: 316, height: 30)
        let pill = Lanes.bandPill(width: band.width, height: band.height)
        check("band pill: inset 8 like the rows, so it spans the same x as a row pill",
              pill.minX == Lanes.pillInset && pill.width == Lanes.pillWidth(contentWidth: band.width) && pill.maxX == band.width - Lanes.pillInset)
        check("band pill: a row tall and centered in a 30pt band", pill.height == Lanes.rowHeight && pill.minY == 1 && pill.maxY == 29)
        check("band pill fits a short band: 24 in a 24pt menu bar", Lanes.bandPill(width: 300, height: 24).height == 24 && Lanes.bandPill(width: 300, height: 24).minY == 0)
        let titleEnd = Lanes.textStart + 80
        let countStart = band.width - Lanes.padding - 30
        check("off the letters, right of the title and left of the count, is on task 1", pill.contains(CGPoint(x: (titleEnd + countStart) / 2, y: 15)))
        check("the dot, the title and the count are on task 1",
              pill.contains(CGPoint(x: Lanes.slotStart + 9, y: 15)) && pill.contains(CGPoint(x: Lanes.textStart + 10, y: 15)) && pill.contains(CGPoint(x: countStart + 10, y: 15)))
        check("the 8pt inset beside the pill is not", !pill.contains(CGPoint(x: 4, y: 15)) && !pill.contains(CGPoint(x: band.width - 4, y: 15)))
        check("the gap under the band is not: row 2 starts after it", !pill.contains(CGPoint(x: 150, y: band.height + Lanes.topGap / 2)))
        // In panel space the band pill sits inside the open shape, so hovering it keeps the card open.
        let shape = CGRect(x: 242, y: 0, width: band.width + 2 * NotchGeometry.flare, height: 158)
        let inPanel = pill.offsetBy(dx: shape.minX + NotchGeometry.flare, dy: 0)
        check("the whole band pill is inside the open shape",
              [CGPoint(x: inPanel.minX, y: inPanel.minY), CGPoint(x: inPanel.maxX, y: inPanel.maxY)].allSatisfy { NotchHover.inside($0, shape: shape, isOpen: true) })
    }

    section("Router actions")
    let list = TaskList(["A", "B"])
    let host = ["host": "localhost"]
    let put = MainThingRouter.handle(HTTPRequest(method: "PUT", path: "/tasks", headers: host, body: Data("[\" X \",\"Y\"]".utf8)), list: list)
    check("PUT asks the store to replace with the decoded titles", put.action == .replace([" X ", "Y"], source: "api"))
    let done = MainThingRouter.handle(HTTPRequest(method: "POST", path: "/tasks/done", headers: host), list: list)
    check("POST /tasks/done asks the store to complete the first key", done.action == .complete(key: "A#0", source: "api"))
    let get = MainThingRouter.handle(HTTPRequest(method: "GET", path: "/tasks", headers: host), list: list)
    check("GET asks for nothing", get.action == .none)
    let bad = MainThingRouter.handle(HTTPRequest(method: "PUT", path: "/tasks", headers: host, body: Data("x".utf8)), list: list)
    check("bad PUT asks for nothing", bad.action == .none)
    let refused = MainThingRouter.handle(HTTPRequest(method: "POST", path: "/tasks/done", headers: ["host": "evil"]), list: list)
    check("refused request asks for nothing", refused.action == .none)
}
