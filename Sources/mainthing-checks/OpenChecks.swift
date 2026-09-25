import CoreGraphics
import Foundation
import MainThingCore

@MainActor
func runOpenChecks() {
    section("Complete by key")
    do {
        var list = TaskList(["A", TaskItem("B", ref: "ob:2"), "C"])
        check("key(at:) 0 based", list.key(at: 0) == "A#0" && list.key(at: 2) == "C#0" && list.key(at: 3) == nil && list.key(at: -1) == nil)
        check("key(ref:)", list.key(ref: "ob:2") == "ref:ob:2" && list.key(ref: "ob:9") == nil)
        check("complete the third row by key", list.complete(key: "C#0", expected: nil) == TaskItem("C") && list.titles == ["A", "B"])
        check("complete a ref'd row by key", list.complete(key: "ref:ob:2", expected: "B") == TaskItem("B", ref: "ob:2") && list.titles == ["A"])
        check("stale title on the key does nothing", list.complete(key: "A#0", expected: "Not A") == nil && list.titles == ["A"])
        check("unknown key does nothing", list.complete(key: "Z#0", expected: nil) == nil && list.titles == ["A"])
        check("complete(expected:) is the first key", list.complete(expected: "A") == TaskItem("A") && list.isEmpty)
    }

    section("POST /tasks/done target")
    do {
        let list = TaskList(["A", TaskItem("B", ref: "ob:2"), "C"])
        let host = ["host": "localhost"]
        check("empty body: the first", MainThingRouter.doneTarget(body: Data(), list: list) == .success("A#0"))
        check("{} body: the first", MainThingRouter.doneTarget(body: Data("{}".utf8), list: list) == .success("A#0"))
        check("empty body on an empty list: nothing", MainThingRouter.doneTarget(body: Data(), list: TaskList()) == .success(nil))
        check("index 2", MainThingRouter.doneTarget(body: Data("{\"index\":2}".utf8), list: list) == .success("C#0"))
        check("index 3 is 404", MainThingRouter.doneTarget(body: Data("{\"index\":3}".utf8), list: list) == .failure(RouteFailure(404, "no task at index 3, the list has 3")))
        check("negative index is 404", MainThingRouter.doneTarget(body: Data("{\"index\":-1}".utf8), list: list) == .failure(RouteFailure(404, "no task at index -1, the list has 3")))
        check("string index is 400", MainThingRouter.doneTarget(body: Data("{\"index\":\"2\"}".utf8), list: list) == .failure(RouteFailure(400, "index must be a whole number, 0 based")))
        check("index 1 and 0 are numbers, not booleans", MainThingRouter.doneTarget(body: Data("{\"index\":1}".utf8), list: list) == .success("ref:ob:2") && MainThingRouter.doneTarget(body: Data("{\"index\":0}".utf8), list: list) == .success("A#0"))
        check("boolean index is 400", MainThingRouter.doneTarget(body: Data("{\"index\":true}".utf8), list: list) == .failure(RouteFailure(400, "index must be a whole number, 0 based")))
        check("fractional index is 400", MainThingRouter.doneTarget(body: Data("{\"index\":1.5}".utf8), list: list).isFailure)
        check("ref", MainThingRouter.doneTarget(body: Data("{\"ref\":\"ob:2\"}".utf8), list: list) == .success("ref:ob:2"))
        check("unknown ref is 404", MainThingRouter.doneTarget(body: Data("{\"ref\":\"ob:9\"}".utf8), list: list) == .failure(RouteFailure(404, "no task with ref ob:9")))
        check("other body is 400", MainThingRouter.doneTarget(body: Data("[1]".utf8), list: list).isFailure)
        check("other keys are 400", MainThingRouter.doneTarget(body: Data("{\"title\":\"A\"}".utf8), list: list).isFailure)

        let byIndex = MainThingRouter.handle(HTTPRequest(method: "POST", path: "/tasks/done", headers: host, body: Data("{\"index\":2}".utf8)), list: list)
        check("POST /tasks/done {index:2} removes C", byIndex.action == .complete(key: "C#0", source: "api") && byIndex.list.titles == ["A", "B"] && byIndex.changed)
        let byRef = MainThingRouter.handle(HTTPRequest(method: "POST", path: "/tasks/done", headers: host, body: Data("{\"ref\":\"ob:2\"}".utf8)), list: list)
        check("POST /tasks/done {ref} removes B", byRef.action == .complete(key: "ref:ob:2", source: "api") && byRef.list.titles == ["A", "C"])
        let missing = MainThingRouter.handle(HTTPRequest(method: "POST", path: "/tasks/done", headers: host, body: Data("{\"index\":7}".utf8)), list: list)
        check("POST /tasks/done past the end is 404 and changes nothing", missing.response.status == 404 && missing.action == .none && missing.list == list)
        let empty = MainThingRouter.handle(HTTPRequest(method: "POST", path: "/tasks/done", headers: host), list: TaskList())
        check("POST /tasks/done on empty is 200 and asks nothing", empty.response.status == 200 && empty.action == .none)
    }

    section("OpenLayout")
    do {
        let screen: CGFloat = 2560
        check("row chrome is 64", OpenLayout.rowChrome == 64)
        check("short list keeps the 420 minimum", OpenLayout.width(titleWidths: [120, 80, 200], screenWidth: screen) == 420)
        check("empty list keeps the minimum", OpenLayout.width(titleWidths: [], screenWidth: screen) == 420)
        check("a long title sets the width", OpenLayout.width(titleWidths: [120, 500.4], screenWidth: screen) == 565)
        check("the 640 cap holds", OpenLayout.width(titleWidths: [900], screenWidth: screen) == 640)
        check("half of a small screen caps below 640", OpenLayout.width(titleWidths: [900], screenWidth: 1000) == 500)
        check("width cap is the smaller of 640 and half the screen", OpenLayout.widthCap(screenWidth: 1512) == 640 && OpenLayout.widthCap(screenWidth: 1200) == 600)
        check("title width is the card minus the chrome", OpenLayout.titleWidth(contentWidth: 420) == 356)

        check("content height: rows, spacing, padding", OpenLayout.contentHeight(rowHeights: [22, 18, 18]) == 2 + 58 + 12 + 14)
        check("content height with two note lines", OpenLayout.contentHeight(rowHeights: [22]) + 2 * (14 + 6) == OpenLayout.contentHeight(rowHeights: [22], notes: 2))
        check("content height of an empty list is one line", OpenLayout.contentHeight(rowHeights: []) == 2 + 18 + 14)

        let small = OpenLayout.panelHeight(notchHeight: 30, contentHeight: 100, screenHeight: 1440, minimum: 260)
        check("a short card keeps the 260 minimum and does not scroll", small.panel == 260 && small.rowsMax == nil)
        let mid = OpenLayout.panelHeight(notchHeight: 30, contentHeight: 400, screenHeight: 1440, minimum: 260)
        check("a taller card grows the panel with 40pt headroom", mid.panel == 470 && mid.rowsMax == nil)
        let tall = OpenLayout.panelHeight(notchHeight: 30, contentHeight: 2000, screenHeight: 1440, minimum: 260)
        check("past 60 percent of the screen the panel caps at 864", tall.panel == 864)
        check("and the rows scroll inside what is left", tall.rowsMax == 864 - 30 - 40 - 2 - 14)
        let edge = OpenLayout.panelHeight(notchHeight: 30, contentHeight: 794, screenHeight: 1440, minimum: 260)
        check("exactly at the cap: no scrolling", edge.panel == 864 && edge.rowsMax == nil)
    }

    section("Pending completions")
    do {
        var pending = PendingCompletions()
        check("nothing pending at first", !pending.isPending("A#0"))
        check("a click arms", pending.toggle("A#0") == .armed && pending.isPending("A#0"))
        check("finish removes it and says to complete", pending.finish("A#0") == true && !pending.isPending("A#0"))
        check("finish on a row that is not pending says no", pending.finish("A#0") == false)
        _ = pending.toggle("B#0")
        _ = pending.toggle("C#0")
        pending.keep(only: ["C#0"])
        check("keep(only:) drops rows that left the list", !pending.isPending("B#0") && pending.isPending("C#0"))
    }
}
