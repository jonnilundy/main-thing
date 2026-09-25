import CoreGraphics
import Foundation
import NextUpCore

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

    check("collapsed, cursor enters: schedule open", NotchHover.intent(isOpen: false, pendingOpen: false, inside: true) == .scheduleOpen)
    check("collapsed, pending, still inside: nothing", NotchHover.intent(isOpen: false, pendingOpen: true, inside: true) == .none)
    check("collapsed, pending, cursor leaves: cancel", NotchHover.intent(isOpen: false, pendingOpen: true, inside: false) == .cancelOpen)
    check("collapsed, outside, nothing pending: nothing", NotchHover.intent(isOpen: false, pendingOpen: false, inside: false) == .none)
    check("open, inside: nothing", NotchHover.intent(isOpen: true, pendingOpen: false, inside: true) == .none)
    check("open, cursor leaves: close", NotchHover.intent(isOpen: true, pendingOpen: false, inside: false) == .close)
    check("open delay is 40ms", NotchHover.openDelay == .milliseconds(40))
    check("slack is 8pt", NotchHover.slack == 8)

    // AppKit screen points on a 1440pt tall screen, panel 800x240 at the top center.
    let panel = CGRect(x: 880, y: 1200, width: 800, height: 240)
    check("panel point: 10pt under the screen top at center is (400, 10)",
          NotchHover.panelPoint(screenPoint: CGPoint(x: 1280, y: 1430), panelFrame: panel) == CGPoint(x: 400, y: 10))
    check("panel point: the panel's top left is (0, 0)",
          NotchHover.panelPoint(screenPoint: CGPoint(x: 880, y: 1440), panelFrame: panel) == .zero)

    section("Router actions")
    let list = TaskList(["A", "B"])
    let host = ["host": "localhost"]
    let put = NextUpRouter.handle(HTTPRequest(method: "PUT", path: "/tasks", headers: host, body: Data("[\" X \",\"Y\"]".utf8)), list: list)
    check("PUT asks the store to replace with the decoded titles", put.action == .replace([" X ", "Y"]))
    let done = NextUpRouter.handle(HTTPRequest(method: "POST", path: "/tasks/done", headers: host), list: list)
    check("POST /tasks/done asks the store to complete", done.action == .complete)
    let get = NextUpRouter.handle(HTTPRequest(method: "GET", path: "/tasks", headers: host), list: list)
    check("GET asks for nothing", get.action == .none)
    let bad = NextUpRouter.handle(HTTPRequest(method: "PUT", path: "/tasks", headers: host, body: Data("x".utf8)), list: list)
    check("bad PUT asks for nothing", bad.action == .none)
    let refused = NextUpRouter.handle(HTTPRequest(method: "POST", path: "/tasks/done", headers: ["host": "evil"]), list: list)
    check("refused request asks for nothing", refused.action == .none)
}
