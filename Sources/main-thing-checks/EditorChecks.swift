import CoreGraphics
import Foundation
import MainThingCore

@MainActor
func runEditorChecks() {
    section("EditorDraft")
    let base: [TaskItem] = [TaskItem("Ship it", ref: "openbrain:a1"), "Write memo", TaskItem("Call Sam", ref: "openbrain:c3")]

    do {
        let draft = EditorDraft(base)
        check("draft opens on the list", draft.result() == base && draft.base == base)
        check("draft rows carry the refs", draft.rows.map(\.ref) == ["openbrain:a1", nil, "openbrain:c3"])
        check("draft row ids are distinct", Set(draft.rows.map(\.id)).count == 3)
        check("unedited draft is not edited", !draft.isEdited)
        check("unedited draft has no conflict with its base", !draft.conflict(current: base))
    }

    do {
        var draft = EditorDraft(base)
        let ids = draft.rows.map(\.id)
        draft.move(from: 2, to: 0)
        check("move last to first", draft.result().map(\.title) == ["Call Sam", "Ship it", "Write memo"])
        check("move keeps ids and refs with their rows", draft.rows.map(\.id) == [ids[2], ids[0], ids[1]] && draft.result()[0].ref == "openbrain:c3")
        draft.move(from: 0, to: 2)
        check("move first to last", draft.result().map(\.title) == ["Ship it", "Write memo", "Call Sam"])
        draft.move(from: 1, to: 1)
        check("move onto itself changes nothing", draft.rows.map(\.id) == ids)
        draft.move(from: 0, to: 99)
        check("move past the end clamps to the end", draft.result().map(\.title) == ["Write memo", "Call Sam", "Ship it"])
        draft.move(from: 7, to: 0)
        check("move from outside the rows does nothing", draft.result().map(\.title) == ["Write memo", "Call Sam", "Ship it"])
        check("a reorder is an edit", draft.isEdited)
    }

    do {
        var draft = EditorDraft(base)
        let first = draft.rows[0].id
        let new = draft.insert(after: first)
        check("insert after lands right below", draft.rows.map(\.id).firstIndex(of: new) == 1 && draft.rows.count == 4)
        check("an inserted row is blank and has no ref", draft.rows[1].title.isEmpty && draft.rows[1].ref == nil)
        check("a blank row is dropped from the result", draft.result() == base && !draft.isEdited)
        draft.rename(id: new, title: "  New thing  ")
        check("a named new row is kept, trimmed, without a ref", draft.result()[1] == TaskItem("New thing"))
        let top = draft.insert(after: nil, title: "Top")
        check("insert after nil goes to the top", draft.rows.first?.id == top)
        let end = draft.insert(after: UUID(), title: "End")
        check("insert after an unknown id goes to the end", draft.rows.last?.id == end)
        check("insert order", draft.result().map(\.title) == ["Top", "Ship it", "New thing", "Write memo", "Call Sam", "End"])
    }

    do {
        var draft = EditorDraft(base)
        let ids = draft.rows.map(\.id)
        check("remove the middle focuses the row above", draft.remove(id: ids[1]) == ids[0])
        check("removed row is gone", draft.result() == [base[0], base[2]])
        check("remove the first focuses the new first", draft.remove(id: ids[0]) == ids[2])
        check("remove an unknown id does nothing", draft.remove(id: UUID()) == nil && draft.rows.count == 1)
        check("remove the last row leaves nothing to focus", draft.remove(id: ids[2]) == nil && draft.rows.isEmpty)
        check("an emptied draft saves an empty list", draft.result().isEmpty && draft.isEdited)
    }

    do {
        var draft = EditorDraft(base)
        let ids = draft.rows.map(\.id)
        draft.rename(id: ids[0], title: "Ship it today")
        check("rename keeps the ref", draft.result()[0] == TaskItem("Ship it today", ref: "openbrain:a1"))
        draft.rename(id: ids[1], title: " Write the memo ")
        check("rename trims and a row without a ref stays without", draft.result()[1] == TaskItem("Write the memo"))
        draft.rename(id: ids[2], title: "   ")
        check("renaming to blank drops the row, ref and all", draft.result() == [TaskItem("Ship it today", ref: "openbrain:a1"), "Write the memo"])
        draft.rename(id: UUID(), title: "Nobody")
        check("rename of an unknown id does nothing", draft.result().count == 2)
    }

    do {
        let draft = EditorDraft(base)
        check("conflict: a title changed live", draft.conflict(current: [TaskItem("Ship it now", ref: "openbrain:a1"), "Write memo", TaskItem("Call Sam", ref: "openbrain:c3")]))
        check("conflict: a task was added live", draft.conflict(current: base + ["Agent added"]))
        check("conflict: a task was completed live", draft.conflict(current: Array(base.dropFirst())))
        check("conflict: a ref changed live", draft.conflict(current: [TaskItem("Ship it", ref: "openbrain:zz"), "Write memo", TaskItem("Call Sam", ref: "openbrain:c3")]))
        check("conflict: the order changed live", draft.conflict(current: [base[1], base[0], base[2]]))
        check("no conflict when the live list is the base", !draft.conflict(current: base))
        check("empty base, empty live list: no conflict", !EditorDraft([]).conflict(current: []))
    }

    section("Editor save events")
    do {
        // The editor's Save is a replace: removing a ref'd task sends list-changed only, no adapter.
        var draft = EditorDraft(base)
        draft.remove(id: draft.rows[0].id)
        let before = TaskList(base)
        var after = before
        after.replace(draft.result())
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let events = EventPlan.events(before: before, after: after, completed: nil, source: EventSource.editor, at: at)
        check("editor save of a removal is one list-changed event", events.map(\.event) == [.listChanged])
        check("editor save is attributed to the editor", events.first?.source == "editor" && EventSource.problem(EventSource.editor) == nil)
        check("editor save carries no completed task", events.first?.task == nil)
        let config = URL(fileURLWithPath: "/tmp/cfg", isDirectory: true)
        let jobs = events.flatMap { EventPlan.jobs(for: $0, configDirectory: config, exists: { _ in true }) }
        check("editor save runs no adapter, even with every adapter installed", jobs.allSatisfy { $0.kind == .hook } && jobs.map(\.name) == ["list-changed"])
        check("the removed ref'd task is gone after the save", after.key(ref: "openbrain:a1") == nil && after.count == 2)
        let unchanged = EventPlan.events(before: before, after: before, completed: nil, source: EventSource.editor, at: at)
        check("editor save with no change sends nothing", unchanged.isEmpty)
    }

    section("EditorLayout")
    check("editor is 360 wide with the card radius", EditorLayout.width == 360 && EditorLayout.radius == 24)
    check("rows block grows a row at a time", EditorLayout.rowsHeight(rows: 3) == 3 * Lanes.rowHeight)
    check("rows block caps at 12 rows", EditorLayout.rowsHeight(rows: 30) == 12 * Lanes.rowHeight && EditorLayout.rowsHeight(rows: 12) == 12 * Lanes.rowHeight)
    check("rows block never below one row", EditorLayout.rowsHeight(rows: 0) == Lanes.rowHeight)
    check("scrolls past 12 rows only", !EditorLayout.scrolls(rows: 12) && EditorLayout.scrolls(rows: 13))
    check("height: padding, rows, gap, buttons, padding", EditorLayout.height(rows: 2) == 12 + 56 + 8 + 26 + 12)
    check("the conflict message adds a line", EditorLayout.height(rows: 2, conflict: true) == EditorLayout.height(rows: 2) + 24)
    check("height stops growing at 12 rows", EditorLayout.height(rows: 40) == EditorLayout.height(rows: 12))
    check("default spot is centered under the notch", EditorLayout.defaultTopLeft(centerX: 1280, notchBottom: 30) == CGPoint(x: 1100, y: 40))
    let visible = CGRect(x: 0, y: 30, width: 2560, height: 1410)
    let inside = CGRect(x: 100, y: 200, width: 360, height: 200)
    check("clamp leaves a window on screen alone", EditorLayout.clamp(inside, into: visible) == inside)
    check("clamp pulls a window back from the right", EditorLayout.clamp(CGRect(x: 2400, y: 200, width: 360, height: 200), into: visible).maxX == 2552)
    check("clamp pulls a window down from under the menu bar", EditorLayout.clamp(CGRect(x: 100, y: 0, width: 360, height: 200), into: visible).minY == 38)
    check("clamp pulls a window up from below the screen", EditorLayout.clamp(CGRect(x: 100, y: 1400, width: 360, height: 200), into: visible).maxY == 1432)
    check("clamp keeps the size", EditorLayout.clamp(CGRect(x: -500, y: -500, width: 360, height: 200), into: visible).size == CGSize(width: 360, height: 200))
}

@MainActor
func runTearOffChecks() {
    section("TearOff")
    check("no stretch without travel", TearOff.stretch(travel: 0) == 0 && TearOff.stretch(travel: -30) == 0)
    check("the band starts at almost 1:1", TearOff.stretch(travel: 2) > 1.9)
    check("the band resists more and more", TearOff.stretch(travel: 20) - TearOff.stretch(travel: 10) < TearOff.stretch(travel: 10))
    check("the tear threshold is 40pt of travel", abs(TearOff.threshold - 40) < 0.001)
    check("the card is 24pt past its edge at the threshold", abs(TearOff.stretch(travel: TearOff.threshold) - 24) < 0.001)
    check("stretch stays under the band dimension", TearOff.stretch(travel: 10_000) < TearOff.bandDimension)

    do {
        var drag = TearOffDrag(start: CGPoint(x: 100, y: 50), reduceMotion: false)
        check("a press is a click", drag.release() == .click && !drag.moved)
        drag.move(to: CGPoint(x: 103, y: 54))
        check("a 5pt move is still a click", drag.phase == .press && drag.release() == .click && drag.stretch == 0)
        drag.move(to: CGPoint(x: 100, y: 56))
        check("6pt down starts the tear off", drag.phase == .stretch && drag.moved)
        check("the card stretches with the rubber band", abs(drag.stretch - TearOff.stretch(travel: 6)) < 0.001)
        check("a release before the threshold springs back", drag.release() == .springBack)
        drag.move(to: CGPoint(x: 100, y: 50))
        check("back at the start is no click again", drag.moved && drag.release() == .springBack && drag.stretch == 0)
        drag.move(to: CGPoint(x: 100, y: 89))
        check("39pt of travel does not tear", drag.phase == .stretch && drag.stretch < 24)
        drag.move(to: CGPoint(x: 100, y: 90))
        check("40pt of travel tears", drag.phase == .torn && drag.stretch == 0)
        drag.move(to: CGPoint(x: 400, y: 20))
        check("torn stays torn wherever the cursor goes", drag.phase == .torn && drag.release() == .drop)
    }
    do {
        var drag = TearOffDrag(start: CGPoint(x: 100, y: 50), reduceMotion: false)
        drag.move(to: CGPoint(x: 140, y: 50))
        check("a sideways drag is a drag, with no stretch", drag.phase == .stretch && drag.stretch == 0 && drag.release() == .springBack)
        var up = TearOffDrag(start: CGPoint(x: 100, y: 50), reduceMotion: false)
        up.move(to: CGPoint(x: 100, y: 10))
        check("an upward drag never stretches", up.phase == .stretch && up.travel == 0 && up.stretch == 0)
    }
    do {
        var drag = TearOffDrag(start: CGPoint(x: 100, y: 50), reduceMotion: true)
        drag.move(to: CGPoint(x: 100, y: 70))
        check("Reduce Motion: no stretch", drag.phase == .stretch && drag.stretch == 0)
        drag.move(to: CGPoint(x: 100, y: 200))
        check("Reduce Motion: no tracking past the threshold", drag.phase == .stretch && drag.stretch == 0)
        check("Reduce Motion: the editor appears on release past the threshold", drag.release() == .appear)
        drag.move(to: CGPoint(x: 100, y: 80))
        check("Reduce Motion: back above the threshold springs back", drag.release() == .springBack)
    }
    let size = CGSize(width: 360, height: 150)
    check("a grab inside the editor is kept", TearOff.grab(CGPoint(x: 120, y: 40), in: size) == CGPoint(x: 120, y: 40))
    check("a grab past the editor's right edge is pulled in", TearOff.grab(CGPoint(x: 430, y: 40), in: size).x == 348)
    check("a grab below the editor is pulled in", TearOff.grab(CGPoint(x: 120, y: 300), in: size).y == 138)
    check("a grab in the flare is pulled in", TearOff.grab(CGPoint(x: -4, y: 2), in: size) == CGPoint(x: 12, y: 12))
}
