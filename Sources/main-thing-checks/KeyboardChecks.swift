import Foundation
import MainThingCore

@MainActor
func runUndoChecks() {
    section("UndoStack")
    let list = TaskList([TaskItem("Ship it", ref: "linear:ENG-1"), "Write memo", "Call Sam", "Book room"])
    do {
        var stack = UndoStack()
        check("a new stack is empty", stack.isEmpty && stack.nextExpiry == nil)
        let (afterShip, ship) = list.discarding(key: list.rows[0].key, at: 100, kind: .done)!
        stack.push(ship)
        check("a cross off is held as done, with its ref", ship.kind == .done && ship.task.ref == "linear:ENG-1" && ship.index == 0)
        var shorter = TaskList(afterShip)
        let (afterMemo, memo) = shorter.discarding(key: shorter.rows[0].key, at: 101)!
        stack.push(memo)
        shorter = TaskList(afterMemo)
        check("the newest is last", stack.entries.last == memo)
        check("the next window ends 4 seconds after the oldest", stack.nextExpiry == 104)
        var undoing = stack
        let first = undoing.undo(at: 102)
        check("undo takes the newest first", first == memo)
        let second = undoing.undo(at: 102)
        check("then the one before it", second == ship && undoing.isEmpty)
        let back = ship.restored(into: memo.restored(into: shorter.tasks))
        check("two undos in order put both back where they were", back == list.tasks)
        check("nothing left to undo", undoing.undo(at: 102) == nil)

        var ending = stack
        check("at 103.9 nothing has ended", ending.expire(at: 103.9).isEmpty && ending.entries.count == 2)
        check("at 104 the cross off ends, the discard is still held", ending.expire(at: 104) == [ship] && ending.entries == [memo])
        check("an entry past its window cannot be undone", ending.undo(at: 105.5) == nil)
        check("at 105 the discard ends too", ending.expire(at: 105) == [memo] && ending.isEmpty)

        var quitting = stack
        check("quit drains every entry, oldest first", quitting.drain() == [ship, memo] && quitting.isEmpty)
    }

    section("Held cross off events")
    do {
        let (_, ship) = list.discarding(key: list.rows[0].key, at: 0, kind: .done)!
        let (_, memo) = list.discarding(key: list.rows[1].key, at: 0)!
        let now = TaskList(["Write memo", "Call Sam"])
        let payload = EventPlan.commit(ship, list: now, source: EventSource.notch, at: Date(timeIntervalSince1970: 0))
        check("a cross off commits task-completed with its ref", payload?.event == .taskCompleted && payload?.task == TaskItem("Ship it", ref: "linear:ENG-1"))
        check("with the list as it is when the window ends", payload?.tasks == now.tasks && payload?.source == EventSource.notch)
        check("a discard commits nothing", EventPlan.commit(memo, list: now, source: EventSource.notch, at: Date()) == nil)
        let config = URL(fileURLWithPath: "/tmp/mt-config")
        let jobs = payload.map { EventPlan.jobs(for: $0, configDirectory: config) { _ in true } } ?? []
        check("the commit runs the adapter's complete, then the done hook", jobs.map(\.name) == ["linear", "task-completed"] && jobs.first?.arguments == ["complete", "ENG-1"])
        let removal = EventPlan.events(before: list, after: TaskList(Array(list.tasks.dropFirst())), completed: nil, source: EventSource.notch, at: Date())
        check("when the row leaves only list-changed goes out", removal.map(\.event) == [.listChanged])
    }
}

@MainActor
func runKeyboardChecks() {
    section("Card keys")
    typealias C = CardKeys.Code
    func key(_ code: UInt16, _ chars: String? = nil, _ mods: KeyModifiers = []) -> CardKey? {
        CardKeys.action(keyCode: code, characters: chars, modifiers: mods)
    }
    check("down and up step the highlight", key(C.down) == .step(1) && key(C.up) == .step(-1))
    check("option down and up move the task", key(C.down, nil, .option) == .moveTask(1) && key(C.up, nil, .option) == .moveTask(-1))
    check("tab and shift tab cycle", key(C.tab, "\t") == .cycle(1) && key(C.tab, "\t", .shift) == .cycle(-1))
    check("return and enter activate", key(C.returnKey, "\r") == .activate && key(C.keypadEnter, "\u{3}") == .activate)
    check("delete, forward delete and command delete discard", key(C.delete) == .discard && key(C.forwardDelete) == .discard && key(C.delete, nil, .command) == .discard)
    check("escape", key(C.escape) == .escape)
    check("E renames, N goes to New task", key(14, "e") == .rename && key(45, "n") == .newTask)
    check("letters follow the layout: the key that types e renames", key(3, "e") == .rename && key(14, "f") == nil)
    check("command Z undoes", key(6, "z", .command) == .undo)
    check("plain Z, shift command Z and option Z are no card key", key(6, "z") == nil && key(6, "z", [.command, .shift]) == nil && key(6, "z", .option) == nil)
    check("command E, command N and shift E go on as usual", key(14, "e", .command) == nil && key(45, "n", .command) == nil && key(14, "E", .shift) == nil)
    check("control anything goes on as usual", key(C.down, nil, .control) == nil && key(C.returnKey, "\r", .control) == nil)
    check("command return and command up go on as usual", key(C.returnKey, "\r", .command) == nil && key(C.up, nil, .command) == nil)
    check("other letters go on as usual", key(0, "a") == nil && key(1, "s", .command) == nil)

    section("Keyboard highlight")
    let n = 3
    check("the slots: every task, then New task", CardKeys.slots(taskCount: n) == [.task(0), .task(1), .task(2), .add])
    check("empty list: New task only", CardKeys.slots(taskCount: 0) == [.add])
    check("down from nothing is task 1", CardKeys.step(from: .none, by: 1, taskCount: n, wraps: false) == .task(0))
    check("up from nothing is New task", CardKeys.step(from: .none, by: -1, taskCount: n, wraps: false) == .add)
    check("down from task 1 is task 2", CardKeys.step(from: .task(0), by: 1, taskCount: n, wraps: false) == .task(1))
    check("down from the last task is New task", CardKeys.step(from: .task(2), by: 1, taskCount: n, wraps: false) == .add)
    check("arrows stop at the ends", CardKeys.step(from: .add, by: 1, taskCount: n, wraps: false) == .add && CardKeys.step(from: .task(0), by: -1, taskCount: n, wraps: false) == .task(0))
    check("tab wraps past New task to task 1", CardKeys.step(from: .add, by: 1, taskCount: n, wraps: true) == .task(0))
    check("shift tab wraps past task 1 to New task", CardKeys.step(from: .task(0), by: -1, taskCount: n, wraps: true) == .add)
    check("a task that is gone steps like no highlight", CardKeys.step(from: .task(7), by: 1, taskCount: n, wraps: false) == .task(0))
    check("empty list: every step is New task", CardKeys.step(from: .none, by: 1, taskCount: 0, wraps: true) == .add && CardKeys.step(from: .add, by: -1, taskCount: 0, wraps: true) == .add)
    check("clamp: the last task crossed off moves to the new last", CardKeys.clamp(.task(3), taskCount: 3) == .task(2))
    check("clamp: no task left moves to New task", CardKeys.clamp(.task(0), taskCount: 0) == .add)
    check("clamp: a task still there stays", CardKeys.clamp(.task(1), taskCount: 3) == .task(1) && CardKeys.clamp(.add, taskCount: 0) == .add)
}
