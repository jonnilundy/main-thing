import CoreGraphics
import Foundation
import MainThingCore

@MainActor
func runCardChecks() {
    section("CardMap")
    // Band 30 tall, gap 6, rows from 36: row 2 36..64, row 3 64..92, row 4 92..120, add 120..148.
    let map = CardMap(notchHeight: 30, taskCount: 4)
    check("the rows start under the gap", map.rowsTop == 36 && map.rowItems == 3)
    check("the card: band, gap, three rows, add card, padding", map.height == 30 + 6 + 84 + 28 + 10)
    check("the band is task 1", map.slot(atY: 0) == .task(0) && map.slot(atY: 29) == .task(0))
    check("the upper half of the gap is the band", map.slot(atY: 32.9) == .task(0))
    check("the lower half of the gap is row 2", map.slot(atY: 33) == .task(1))
    check("rows by the pointer's y", map.slot(atY: 50) == .task(1) && map.slot(atY: 64) == .task(2) && map.slot(atY: 119.9) == .task(3))
    check("the very bottom is the add card", map.slot(atY: 120) == .add && map.slot(atY: 147) == .add && map.slot(atY: 160) == .add)
    check("above the card is the band", map.slot(atY: -5) == .task(0))
    do {
        var owner: [CardSlot] = []
        var y: CGFloat = 0
        while y < map.height { owner.append(map.slot(atY: y)); y += 0.5 }
        check("every height of the card belongs to a slot", !owner.contains(.none))
        let changes = zip(owner, owner.dropFirst()).filter { $0 != $1 }.count
        check("top to bottom the slots come once each, in order", changes == 4)
    }
    check("the task centers: the band, then the rows", map.taskCenters == [15, 50, 78, 106])

    let single = CardMap(notchHeight: 30, taskCount: 1)
    check("one task: the band, then the add card, no gap between", single.slot(atY: 32) == .task(0) && single.slot(atY: 34) == .add)
    let empty = CardMap(notchHeight: 30, taskCount: 0)
    check("no tasks: the line is no slot, the add card is below it", empty.slot(atY: 40) == .none && empty.slot(atY: empty.addTop + 1) == .add)
    check("no tasks: above the line is not the band", empty.slot(atY: 5) == .none)
    let noted = CardMap(notchHeight: 30, taskCount: 2, notesHeight: 20)
    check("a note line under the rows is no slot", noted.slot(atY: 64 + 10) == .none && noted.slot(atY: 64 + 20 + 5) == .add)

    let undo = CardMap(notchHeight: 30, taskCount: 3, undoRow: 1)
    check("the Undo takes its own row", undo.rowItems == 3 && undo.item(atRow: 0) == .task(1) && undo.item(atRow: 1) == .undo && undo.item(atRow: 2) == .task(2))
    check("the Undo row by the pointer", undo.slot(atY: 64 + 14) == .undo && undo.slot(atY: 92 + 14) == .task(2))
    check("task positions skip the Undo", undo.position(ofTask: 1) == 0 && undo.position(ofTask: 2) == 2 && undo.position(ofTask: 0) == nil)
    check("live centers step over the Undo row", undo.liveCenters == [15, 50, 106] && undo.centerY(of: .undo) == 78)
    check("without an Undo the live centers are the resting ones", map.liveCenters == map.taskCenters && map.centerY(of: .add) == 134)
    let lastUndo = CardMap(notchHeight: 30, taskCount: 0, undoRow: 3)
    check("the last task discarded: the Undo is the only row", !lastUndo.isEmpty && lastUndo.rowItems == 1 && lastUndo.slot(atY: 40) == .undo)
    check("an Undo past the end is clamped to the last row", CardMap(notchHeight: 30, taskCount: 2, undoRow: 7).item(atRow: 1) == .undo)

    let scrolled = CardMap(notchHeight: 30, taskCount: 30, rowsMax: 280, scroll: 56)
    check("scrolled rows: the viewport is 280 tall", scrolled.rowsVisibleHeight == 280 && scrolled.addTop == 36 + 280)
    check("scrolled 2 rows: the first visible row is task 4", scrolled.slot(atY: 40) == .task(3))
    check("scrolled: the add card stays under the viewport", scrolled.slot(atY: 36 + 281) == .add)

    check("the handle lane: from the body edge to half the gap before the title", CardMap.inHandle(x: 0) && CardMap.inHandle(x: 27) && CardMap.inHandle(x: 40.9) && !CardMap.inHandle(x: 41) && !CardMap.inHandle(x: 120))
    check("the handle lane holds the dot and the numbers", CardMap.inHandle(x: Lanes.slotStart) && CardMap.inHandle(x: Lanes.rowSlotStart + Lanes.markerSlot))

    section("Reorder")
    let centers = map.taskCenters
    check("no move stays", Reorder.target(from: 2, offset: 0, centers: centers) == 2)
    check("under half a row stays", Reorder.target(from: 2, offset: 13, centers: centers) == 2)
    check("past half a row takes the next place", Reorder.target(from: 2, offset: 15, centers: centers) == 3)
    check("far down lands last", Reorder.target(from: 1, offset: 900, centers: centers) == 3)
    check("row 2 up past the band's middle lands on top", Reorder.target(from: 1, offset: -30, centers: centers) == 0)
    check("row 2 up a little stays", Reorder.target(from: 1, offset: -15, centers: centers) == 1)
    check("the main task dragged down one row", Reorder.target(from: 0, offset: 36, centers: centers) == 1)
    check("row 4 to the top", Reorder.target(from: 3, offset: -95, centers: centers) == 0)
    check("dragging down: the rows between move up", Reorder.place(of: 2, from: 1, to: 3) == 1 && Reorder.place(of: 3, from: 1, to: 3) == 2)
    check("dragging up: the rows between move down", Reorder.place(of: 0, from: 3, to: 0) == 1 && Reorder.place(of: 2, from: 3, to: 0) == 3)
    check("rows outside the move stay", Reorder.place(of: 0, from: 1, to: 3) == 0 && Reorder.place(of: 3, from: 0, to: 2) == 3)
    check("the dragged one shows at its target", Reorder.place(of: 1, from: 1, to: 3) == 3)
    check("move", Reorder.move(["a", "b", "c", "d"], from: 3, to: 0) == ["d", "a", "b", "c"] && Reorder.move(["a", "b", "c"], from: 0, to: 2) == ["b", "c", "a"])
    check("move from outside does nothing", Reorder.move(["a", "b"], from: 5, to: 0) == ["a", "b"])

    section("CardPress")
    do {
        var press = CardPress(slot: .task(2), start: CGPoint(x: 100, y: 70), onHandle: false)
        check("a press is a click", press.click == .task(2))
        press.move(to: CGPoint(x: 102, y: 71))
        check("a 2pt move is still a click", press.kind == .pressed && press.click == .task(2))
        press.move(to: CGPoint(x: 100, y: 74))
        check("off the handle a drag is no reorder and no click", press.kind == .moved && press.click == nil)
        check("a moved press never opens the menu", press.held() == false)
    }
    do {
        var press = CardPress(slot: .task(2), start: CGPoint(x: 27, y: 70), onHandle: true)
        press.move(to: CGPoint(x: 27, y: 90))
        check("on the handle a drag reorders", press.kind == .reordering && press.offset.height == 20 && press.click == nil)
        press.move(to: CGPoint(x: 50, y: 60))
        check("the offset follows the pointer 1:1", press.offset == CGSize(width: 23, height: -10))
    }
    do {
        var press = CardPress(slot: .task(1), start: CGPoint(x: 27, y: 50), onHandle: true)
        check("held in place opens the menu, handle or not", press.held() && press.kind == .longPressed)
        check("a long press is no click", press.click == nil)
        press.move(to: CGPoint(x: 80, y: 50))
        check("moving after the menu opened is no reorder", press.kind == .longPressed)
    }
    check("the add card has no handle and no menu", { var p = CardPress(slot: .add, start: .zero, onHandle: true); return !p.onHandle && !p.held() && p.click == .add }())
    check("long press time: the system's, kept sane", CardPress.longPressDuration(doubleClickInterval: 0.5) == 0.5 && CardPress.longPressDuration(doubleClickInterval: 0.1) == 0.3 && CardPress.longPressDuration(doubleClickInterval: 5) == 1)

    section("RowMenu")
    let frame = RowMenu.frame(pressX: 150, rowCenterY: 50, cardWidth: 320)
    check("the menu sits in the row, just right of the press", frame == CGRect(x: 156, y: 39, width: RowMenu.width, height: 22))
    check("a release where the press was selects nothing", RowMenu.item(at: CGPoint(x: 150, y: 50), in: frame) == nil)
    let late = RowMenu.frame(pressX: 300, rowCenterY: 50, cardWidth: 320)
    check("no room on the right: the menu opens left of the press", late.maxX == 294 && RowMenu.item(at: CGPoint(x: 300, y: 50), in: late) == nil)
    check("the menu stays inside the pill", RowMenu.frame(pressX: 0, rowCenterY: 50, cardWidth: 320).minX == 10 && RowMenu.frame(pressX: 318, rowCenterY: 50, cardWidth: 320).maxX <= 310)
    check("left half is Rename, right half Discard", RowMenu.item(at: CGPoint(x: frame.minX + 10, y: 50), in: frame) == .rename && RowMenu.item(at: CGPoint(x: frame.maxX - 10, y: 50), in: frame) == .discard)
    check("outside the menu is no item", RowMenu.item(at: CGPoint(x: frame.minX - 1, y: 50), in: frame) == nil)

    section("Discard and Undo")
    let list = TaskList([TaskItem("Ship it", ref: "openbrain:a1"), "Write memo", "Call Sam"])
    do {
        let key = list.rows[1].key
        let (tasks, gone) = list.discarding(key: key, at: 100)!
        check("discard removes the task by key", tasks == [TaskItem("Ship it", ref: "openbrain:a1"), "Call Sam"])
        check("the Undo remembers where it was", gone.task == "Write memo" && gone.index == 1 && gone.undoRow == 0)
        check("the Undo stays 4 seconds", !gone.expired(at: 103.9) && gone.expired(at: 104))
        check("undo puts it back where it was", gone.restored(into: tasks) == list.tasks)
        check("undo into a shorter list puts it at the end", gone.restored(into: []) == ["Write memo"])
        check("discard of a key not there does nothing", list.discarding(key: "Nope#0", at: 0) == nil)
        let main = list.discarding(key: list.rows[0].key, at: 0)!.discarded
        check("the main task's Undo shows in the first row", main.undoRow == 0 && main.index == 0)
        check("a ref that came back is not added twice", main.restored(into: [TaskItem("Ship it again", ref: "openbrain:a1")]).count == 1)
    }

    section("Edits by key")
    check("move a row to the top", list.moving(key: list.rows[2].key, to: 0)?.map(\.title) == ["Call Sam", "Ship it", "Write memo"])
    check("the old main task becomes 2", list.moving(key: list.rows[2].key, to: 0)?[1].title == "Ship it")
    check("move the main task down keeps its ref", list.moving(key: list.rows[0].key, to: 2)?[2] == TaskItem("Ship it", ref: "openbrain:a1"))
    check("move onto itself is no change", list.moving(key: list.rows[1].key, to: 1) == nil)
    check("move past the end clamps", list.moving(key: list.rows[0].key, to: 9)?.last?.title == "Ship it")
    check("move of a key not there is no change", list.moving(key: "Gone#0", to: 0) == nil)
    check("rename keeps the ref and trims", list.renaming(key: "ref:openbrain:a1", to: "  Ship it now ") == [TaskItem("Ship it now", ref: "openbrain:a1"), "Write memo", "Call Sam"])
    check("rename to blank or the same title is no change", list.renaming(key: list.rows[1].key, to: "  ") == nil && list.renaming(key: list.rows[1].key, to: "Write memo") == nil)
    check("rename of a task that is gone is dropped", list.renaming(key: "Gone#0", to: "X") == nil)
    do {
        // An agent rewrote the list while the field was open: the rename still lands on its task.
        var changed = list
        changed.replace([TaskItem("New first"), TaskItem("Ship it", ref: "openbrain:a1"), "Call Sam"])
        check("rename by key after the list moved", changed.renaming(key: "ref:openbrain:a1", to: "Ship it now")?[1] == TaskItem("Ship it now", ref: "openbrain:a1"))
        check("rename after the task left is dropped", changed.renaming(key: list.rows[1].key, to: "Memo") == nil)
    }
    check("add goes to the end, trimmed, without a ref", list.appending("  Book the room ")?.last == TaskItem("Book the room"))
    check("add of a blank title is no change", list.appending("   ") == nil)
}
