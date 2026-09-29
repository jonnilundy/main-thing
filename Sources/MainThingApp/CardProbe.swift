import AppKit
import MainThingCore
import SwiftUI

/// `MainThing --probe-card`: every edit in the open card, end to end, without the real cursor.
///
/// The real notch view, hover rules and card pointer run in an invisible panel (alpha 0, bottom
/// left of the main screen) on a list in memory: no tasks file is read or written, no hook runs,
/// no sound plays, and a counter stands in for the trackpad. Mouse and key events are built as
/// NSEvents and handed to the app's own `sendEvent`, the path real clicks and key presses take after
/// the window server; no CGEvent is posted and the cursor never moves. Fields and the card's key
/// control never take the keyboard: the probe types by setting the field's text. The quit check runs
/// a real done hook from a folder of its own. Prints one line per check and exits 1 when one fails.
/// The events the probe's store sent.
@MainActor
final class SentEvents {
    var payloads: [EventPayload] = []
    var events: [EventKind] { payloads.map(\.event) }
}

@MainActor
enum CardProbe {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        print((ok ? "ok   " : "FAIL ") + name)
    }

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main, let fixture = HoverBench.fixtures["menubar"] else {
            print("probe: no screen")
            exit(1)
        }
        let geometry = NotchGeometry(screen: fixture)
        let store = TaskStore(previewTitles: [])
        let start: [TaskItem] = [
            TaskItem("Ship the launch post", ref: "probe:ship"), "Reply to the design review", "Update the changelog",
            "Book the offsite room", "Draft the Q4 plan",
        ]
        store.replace(start, source: "probe")
        // Every event the store sends, in order. The probe's store runs no hook or adapter.
        let sent = SentEvents()
        store.onEmit = { sent.payloads.append($0) }
        let model = NotchModel(geometry: geometry, apiPort: APIPort.preferred)
        model.hoverAnimates = false
        let haptics = CountingPerformer()
        model.performer = haptics
        model.openWidth = PanelLayout.openWidth(rows: store.list.rows, geometry: geometry)
        let size = CGSize(width: NotchGeometry.panelSize.width, height: 420)
        let frame = CGRect(origin: screen.frame.origin, size: size)
        let panel = NotchPanel(contentRect: frame)
        panel.alphaValue = 0
        let standIn = NotchPanel(contentRect: frame)
        let silent = FileManager.default.temporaryDirectory.appendingPathComponent("main-thing-probe-\(getpid())")
        let sounds = Sounds(configDirectory: silent)
        sounds.muted = true
        // The layout sizes a third panel, never shown: the real layout moves its panel to the
        // fixture screen's notch, which would move the hover rules' panel off this one.
        let sized = NotchPanel(contentRect: frame)
        let hover = HoverController(panel: standIn, model: model, store: store, layout: PanelLayout(panel: sized, model: model, store: store), sounds: sounds)
        let card = CardController(model: model, store: store, panel: panel, toggle: { row in hover.toggleCompletion(of: row) })
        card.takesKeyboard = false
        hover.card = card
        EditMenu.install(on: app)
        check("edit menu: Command V pastes into the field with the keyboard", EditMenu.item(forCommand: "v", in: app)?.action == #selector(NSText.paste(_:)))
        check("edit menu: Command C, X, A and Z are there too", ["c", "x", "a", "z"].allSatisfy { EditMenu.item(forCommand: $0, in: app) != nil })
        store.onChange = { hover.listChanged() }
        let hosting = NotchHostingView(rootView: NotchView(store: store, model: model, onToggle: { row in hover.toggleCompletion(of: row) }, card: card))
        panel.contentView = hosting
        panel.orderFrontRegardless()
        model.isOpen = true
        card.start()

        /// A point on the card to the panel's window coordinates (origin bottom left).
        func window(_ p: CGPoint) -> CGPoint {
            CGPoint(x: model.shapeRect.minX + NotchGeometry.flare + p.x, y: size.height - (model.shapeRect.minY + p.y))
        }
        func send(_ type: NSEvent.EventType, _ p: CGPoint) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: window(p), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1,
                pressure: type == .leftMouseDown || type == .leftMouseDragged ? 1 : 0
            ) else { return }
            if type == .mouseMoved {
                hover.evaluate(at: panel.convertPoint(toScreen: window(p)), source: "local")
                hosting.mouseMoved(with: event)
            } else {
                // The local monitors see it here, as they see a real click.
                app.sendEvent(event)
                if type == .leftMouseDragged { hover.evaluate(at: panel.convertPoint(toScreen: window(p)), source: "local") }
            }
        }
        func wait(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        /// A key press in the panel, through `sendEvent` as a real one goes.
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) async {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code
            ) else { return }
            app.sendEvent(event)
            await wait(30)
        }
        /// The same pointer read again with no move, as a list change does.
        func reread(_ p: CGPoint) { hover.evaluate(at: panel.convertPoint(toScreen: window(p)), source: "refresh") }
        func click(_ p: CGPoint) async {
            send(.mouseMoved, p)
            send(.leftMouseDown, p)
            await wait(30)
            send(.leftMouseUp, p)
            await wait(30)
        }
        /// Press, travel in steps, release.
        func drag(from a: CGPoint, to b: CGPoint) async {
            send(.mouseMoved, a)
            send(.leftMouseDown, a)
            await wait(20)
            for step in 1...12 {
                let t = CGFloat(step) / 12
                send(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                await wait(8)
            }
            send(.leftMouseUp, b)
            await wait(60)
        }
        func longPress(_ p: CGPoint) async {
            send(.mouseMoved, p)
            send(.leftMouseDown, p)
            await wait(Int(CardPress.longPressDuration(doubleClickInterval: NSEvent.doubleClickInterval) * 1000) + 150)
        }
        var titles: [String] { store.list.titles }
        func y(_ index: Int) -> CGFloat { card.map.centerY(of: .task(index)) }
        let title: CGFloat = 120, handle: CGFloat = 27

        Task { @MainActor in
            await wait(800)
            print(String(format: "probe: menu bar row 30pt, card %.0fpt wide, long press %.2fs", model.openWidth, CardPress.longPressDuration(doubleClickInterval: NSEvent.doubleClickInterval)))

            // Hover
            send(.mouseMoved, CGPoint(x: title, y: y(2)))
            check("hover: the pointer on row 3 lights row 3", model.hover == .task(2))
            send(.mouseMoved, CGPoint(x: title, y: card.map.addTop + 10))
            check("hover: the very bottom lights the add card", model.hover == .add)

            // Click crosses off, as before
            let third = store.list.rows[2]
            send(.mouseMoved, CGPoint(x: title, y: y(2)))
            send(.leftMouseDown, CGPoint(x: title, y: y(2)))
            check("press: the row under a press dims", model.pressed == .task(2))
            send(.leftMouseUp, CGPoint(x: title, y: y(2)))
            check("click: a click on the title crosses the task off", model.pending.isPending(third.key))
            sent.payloads = []
            await wait(500)
            check("click: 400ms later the task leaves", !store.list.rows.contains(third))
            check("cross off: an Undo shows in its place", model.discarded?.task == third.task && model.discarded?.kind == .done && card.map.item(atRow: 1) == .undo)
            check("cross off: list-changed went out, task-completed waits for the window", sent.events == [.listChanged])
            await click(CGPoint(x: title, y: card.map.centerY(of: .undo)))
            check("Undo a cross off: the task is back where it was", titles == start.map(\.title))
            check("Undo a cross off: no task-completed ever goes out", !sent.events.contains(.taskCompleted) && model.discarded == nil)
            store.replace(start, source: "probe")
            await wait(100)

            // A drag off the handle is no reorder and no click
            let before = titles
            await drag(from: CGPoint(x: title, y: y(1)), to: CGPoint(x: title, y: y(3)))
            check("drag on the title: no reorder", titles == before)
            check("drag on the title: no cross off", model.pending.keys.isEmpty)

            // Reorder by the number
            await drag(from: CGPoint(x: handle, y: y(3)), to: CGPoint(x: handle, y: y(1)))
            check("reorder: row 4 by its number to 2", titles == ["Ship the launch post", "Book the offsite room", "Reply to the design review", "Update the changelog", "Draft the Q4 plan"])
            check("reorder: no cross off", model.pending.keys.isEmpty)
            check("reorder: ticks mark the places passed", haptics.patterns.filter { $0 == .alignment }.count >= 2)
            await wait(400)
            check("reorder: the held task settles", model.drag == nil)

            // To the top: it becomes the main thing, the old main task is 2
            await drag(from: CGPoint(x: handle, y: y(4)), to: CGPoint(x: handle, y: y(0) - 4))
            check("reorder to the top: it is the main thing", titles.first == "Draft the Q4 plan")
            check("reorder to the top: the old main task is 2", titles[1] == "Ship the launch post" && store.list.rows[1].ref == "probe:ship")
            await wait(400)

            // The main task by its dot, down to 3
            await drag(from: CGPoint(x: handle, y: y(0)), to: CGPoint(x: handle, y: y(2)))
            check("the main task by its dot to 3", titles == ["Ship the launch post", "Book the offsite room", "Draft the Q4 plan", "Reply to the design review", "Update the changelog"])
            await wait(400)
            store.replace(start, source: "probe")
            await wait(100)

            // Long press: the menu, a firm tick, no cross off
            let ticks = haptics.patterns.count
            let second = store.list.rows[1]
            await longPress(CGPoint(x: title, y: y(1)))
            check("long press: the menu opens on its task", model.menu?.key == second.key)
            check("long press: a level change tick at the moment it opens", haptics.patterns.dropFirst(ticks).contains(.levelChange))
            send(.leftMouseUp, CGPoint(x: title, y: y(1)))
            await wait(30)
            check("long press: the release does not cross off", model.pending.keys.isEmpty)
            check("long press: the menu stays for a click", model.menu != nil)

            // Rename: Return saves, by key
            guard let menu = model.menu else { return finish() }
            await click(CGPoint(x: menu.frame.minX + RowMenu.itemWidth / 2, y: menu.frame.midY))
            check("Rename: the title turns into a field", model.renaming == second.key && model.renameText == second.title)
            check("Rename: the menu is gone", model.menu == nil)
            model.renameText = "Reply to the design review today"
            card.submitRename()
            check("Rename: Return saves the new title in place", titles[1] == "Reply to the design review today" && titles.count == 5)

            // Rename: Escape cancels
            await longPress(CGPoint(x: title, y: y(2)))
            send(.leftMouseUp, CGPoint(x: title, y: y(2)))
            if let menu = model.menu { card.choose(.rename, on: menu.key) }
            model.renameText = "Nope"
            card.cancelRename()
            check("Rename: Escape keeps the old title", titles[2] == "Update the changelog" && model.renaming == nil)

            // Rename while the API changes the list: kept by key
            card.startRename("ref:probe:ship")
            model.renameText = "Ship the launch post on Monday"
            store.replace([TaskItem("From the agent"), TaskItem("Ship the launch post", ref: "probe:ship"), "Update the changelog"], source: "api")
            check("API change during a rename: the field and its text stay", model.renaming == "ref:probe:ship" && model.renameText == "Ship the launch post on Monday")
            card.submitRename()
            check("API change during a rename: the rename lands on its task", titles == ["From the agent", "Ship the launch post on Monday", "Update the changelog"] && store.list.rows[1].ref == "probe:ship")
            card.startRename(store.list.rows[2].key)
            store.replace(["From the agent", TaskItem("Ship the launch post on Monday", ref: "probe:ship")], source: "api")
            check("API change during a rename: a task that left drops the rename", model.renaming == nil)
            store.replace(start, source: "probe")
            await wait(100)

            // Discard, then Undo
            let doomed = store.list.rows[2]
            await longPress(CGPoint(x: title, y: y(2)))
            send(.leftMouseUp, CGPoint(x: title, y: y(2)))
            if let menu = model.menu {
                await click(CGPoint(x: menu.frame.maxX - RowMenu.itemWidth / 2, y: menu.frame.midY))
            }
            check("Discard: the task is gone", !titles.contains(doomed.title) && titles.count == 4)
            check("Discard: no cross off ran", model.pending.keys.isEmpty)
            check("Discard: an Undo shows in its place", model.discarded?.task == doomed.task && card.map.item(atRow: 1) == .undo)
            await click(CGPoint(x: title, y: card.map.centerY(of: .undo)))
            check("Undo: the task is back where it was", titles == start.map(\.title))
            check("Undo: the Undo is gone", model.discarded == nil)


            // Discard the main task: the Undo shows in the first row
            card.discard(store.list.rows[0].key)
            check("Discard the main task: the next one is the main thing", titles.first == "Reply to the design review")
            check("Discard the main task: its Undo is the first row", card.map.item(atRow: 0) == .undo)
            card.undo()
            check("Undo the main task: it is the main thing again", titles.first == "Ship the launch post" && store.list.rows[0].ref == "probe:ship")

            // Add
            await click(CGPoint(x: title, y: card.map.addTop + 12))
            check("Add: a click on the add card opens the field", model.adding)
            model.addText = "Book the flights"
            card.submitAdd()
            check("Add: Return adds the task at the end", titles.last == "Book the flights" && titles.count == 6)
            check("Add: the field stays open, empty, for another", model.adding && model.addText.isEmpty)
            check("Add: no hover line on the new row under a still pointer", model.quietPreviewKey == store.list.rows.last?.key)
            send(.mouseMoved, CGPoint(x: title + 20, y: card.map.addTop + 12))
            check("Add: the hover line comes back once the pointer moves", model.quietPreviewKey == nil)
            model.addText = "  "
            card.submitAdd()
            check("Add: a blank title adds nothing", titles.count == 6)
            // Jonni's case: add, then click the new task while the empty field is still open.
            let added = store.list.rows[5]
            await click(CGPoint(x: title, y: y(5)))
            check("Add: a click on a task past the open field closes the field", !model.adding)
            check("Add: and the same click crosses that task off", model.pending.isPending(added.key))
            send(.leftMouseDown, CGPoint(x: title, y: y(5)))
            send(.leftMouseUp, CGPoint(x: title, y: y(5)))
            await wait(50)
            await click(CGPoint(x: title, y: card.map.addTop + 5))
            check("Add: the field opens again", model.adding)
            model.addText = "Half typed"
            send(.mouseMoved, CGPoint(x: title, y: card.map.height + 60))
            check("Add: with text, leaving the card keeps it open", model.adding && model.isOpen)
            model.addText = ""
            send(.mouseMoved, CGPoint(x: title, y: card.map.height + 60))
            check("Add: empty, leaving the card collapses the field", !model.adding)
            send(.mouseMoved, CGPoint(x: title, y: y(1)))
            if !model.isOpen { hover.setOpen(true) }
            await wait(50)
            await click(CGPoint(x: title, y: card.map.addTop + 12))
            card.closeAdd()
            check("Add: Escape collapses it", !model.adding)
            await keys()
            await windows()
            finish()
        }

        /// The card with the keyboard from a shortcut: every key, the highlight against the pointer.
        func keys() async {
            store.replace(start, source: "probe")
            await wait(100)
            let up: UInt16 = CardKeys.Code.up, down: UInt16 = CardKeys.Code.down
            let upChars = "\u{F700}", downChars = "\u{F701}"
            hover.showList()
            // Off the card, before the pointer ever reached it: the pin holds and nothing is lit.
            send(.mouseMoved, CGPoint(x: title, y: card.map.height + 60))
            await wait(50)
            check("keys: Show list gives the card the keyboard", model.isOpen && card.keyboardControl)
            await key(down, downChars)
            check("keys: Down from nothing lights task 1", model.hover == .task(0))
            await key(down, downChars)
            check("keys: Down again lights task 2", model.hover == .task(1))
            await key(up, upChars)
            await key(up, upChars)
            check("keys: Up stops at task 1", model.hover == .task(0))
            await key(CardKeys.Code.tab, "\t", .shift)
            check("keys: Shift Tab from task 1 wraps to New task", model.hover == .add)
            await key(CardKeys.Code.tab, "\t")
            check("keys: Tab from New task wraps to task 1", model.hover == .task(0))

            // The last input wins
            send(.mouseMoved, CGPoint(x: title, y: y(3)))
            check("keys: the pointer moving takes the highlight", model.hover == .task(3))
            await key(down, downChars)
            check("keys: a key takes it back, from where the pointer left it", model.hover == .task(4))
            reread(CGPoint(x: title, y: y(3)))
            check("keys: a still pointer read again does not take it", model.hover == .task(4))
            send(.mouseMoved, CGPoint(x: title + 10, y: y(2)))
            check("keys: the pointer moving takes it again", model.hover == .task(2))

            // Option Up and Down move the highlighted task
            await key(up, upChars)
            await key(down, downChars, .option)
            check("keys: Option Down moves task 2 to 3", titles == ["Ship the launch post", "Update the changelog", "Reply to the design review", "Book the offsite room", "Draft the Q4 plan"])
            check("keys: the highlight goes with it", model.hover == .task(2))
            await key(up, upChars, .option)
            check("keys: Option Up moves it back", titles == start.map(\.title) && model.hover == .task(1))
            await wait(450)
            await key(up, upChars, .option)
            await key(up, upChars, .option)
            check("keys: Option Up to the top makes it the main thing, and stops there", titles.first == "Reply to the design review" && titles[1] == "Ship the launch post" && model.hover == .task(0))
            store.replace(start, source: "probe")
            await wait(450)

            // E renames in place
            await key(down, downChars)
            await key(14, "e")
            check("keys: E opens the rename field on the highlighted task", model.renaming == store.list.rows[1].key)
            await key(down, downChars)
            check("keys: with a field open the arrows are the field's", model.hover == .task(1) && model.renaming != nil)
            model.renameText = "Reply today"
            card.submitRename()
            check("keys: Return saves it, and the card keeps the keyboard", titles[1] == "Reply today" && card.keyboardControl)

            // Delete discards, Command Z brings it back
            sent.payloads = []
            await key(CardKeys.Code.delete, "\u{7F}")
            check("keys: Delete discards the highlighted task", !titles.contains("Reply today") && titles.count == 4)
            check("keys: its Undo shows, the highlight is on the next task", model.discarded?.kind == .discard && model.hover == .task(1) && store.list.rows[1].title == "Update the changelog")
            await key(6, "z", .command)
            check("keys: Command Z puts it back where it was", titles[1] == "Reply today" && model.discarded == nil)
            check("keys: a discard sends no task-completed", !sent.events.contains(.taskCompleted))

            // Return crosses off with the Undo window, Command Z brings it back
            await key(up, upChars)
            await key(CardKeys.Code.returnKey, "\r")
            check("keys: Return crosses off the highlighted task", model.pending.isPending("ref:probe:ship"))
            await wait(500)
            check("keys: the task leaves, its Undo is the first row", titles.first == "Reply today" && model.discarded?.kind == .done && card.map.item(atRow: 0) == .undo)
            await key(6, "z", .command)
            check("keys: Command Z brings the main task back with its ref", titles.first == "Ship the launch post" && store.list.rows[0].ref == "probe:ship")
            check("keys: and its done never went out", !sent.events.contains(.taskCompleted))
            await key(CardKeys.Code.returnKey, "\r")
            await key(6, "z", .command)
            await wait(500)
            check("keys: Command Z during the pen stroke keeps the task, as a second click does", titles.first == "Ship the launch post" && model.pending.keys.isEmpty && model.discarded == nil)

            // N goes to New task
            await key(45, "n")
            check("keys: N opens New task", model.adding && model.hover == .add)
            model.addText = "From the keyboard"
            card.submitAdd()
            check("keys: Return adds it at the end", titles.last == "From the keyboard")
            card.closeAdd()
            check("keys: Escape closes the field, the card stays with the keyboard", !model.adding && model.isOpen && card.keyboardControl)
            await key(0, "a")
            check("keys: a key the card does not use changes nothing", model.isOpen && titles.last == "From the keyboard")

            // Escape closes the card and gives the keyboard back
            await key(CardKeys.Code.escape, "\u{1B}")
            check("keys: Escape closes the card and gives the keyboard back", !model.isOpen && !card.keyboardControl)
            await key(down, downChars)
            check("keys: with the card closed, keys are not the card's", model.hover == .none)
        }

        /// The Undo windows: 5 seconds, a cross off commits at the end, a discard is just gone; undo
        /// with the card closed; the card closing in a pen stroke; quit.
        func windows() async {
            store.replace(start, source: "probe")
            await wait(100)

            // Undo with the card closed: the task just comes back
            hover.crossOffMain()
            await wait(500)
            check("closed: the Cross off shortcut crosses task 1 off", titles.first == "Reply to the design review" && !model.isOpen)
            hover.undoShortcut()
            check("closed: the Undo shortcut brings it back", titles.first == "Ship the launch post" && store.list.rows[0].ref == "probe:ship")

            // The card closing during a pen stroke: the cross off is not lost
            hover.setOpen(true)
            await wait(100)
            let stroked = store.list.rows[2]
            await click(CGPoint(x: title, y: y(2)))
            hover.setOpen(false)
            check("closing in the pen stroke: the task is crossed off, not dropped", !store.list.rows.contains(stroked) && store.undoTop?.task == stroked.task)
            hover.undoShortcut()
            check("and it can be undone", titles == start.map(\.title))

            // A real done hook, from a folder of the probe's own
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("main-thing-card-probe-\(getpid())", isDirectory: true)
            let hooks = EventPlan.hooksDirectory(root.appendingPathComponent("config"))
            let out = root.appendingPathComponent("done.log")
            try? fm.createDirectory(at: hooks, withIntermediateDirectories: true)
            let hook = hooks.appendingPathComponent("task-completed")
            try? "#!/bin/sh\ncat >> \"\(out.path)\"\necho >> \"\(out.path)\"\n".write(to: hook, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
            let real = TaskStore(fileURL: root.appendingPathComponent("tasks.json"), configDirectory: root.appendingPathComponent("config"))
            real.replace([TaskItem("Quit with this held", ref: "probe:quit"), "Commit after the window"], source: "probe")
            func log() -> String { (try? String(contentsOf: out, encoding: .utf8)) ?? "" }
            /// The done hook's runs so far: one payload per line.
            func dones() -> Int { log().split(separator: "\n").filter { $0.contains("\"task-completed\"") }.count }
            real.completeHeld(key: "ref:probe:quit", expected: nil, source: EventSource.notch)
            await wait(300)
            check("quit: in the window the done hook has not run", log().isEmpty)
            real.commitBeforeQuit()
            check("quit: the held cross off commits and its done hook runs before the app exits", dones() == 1 && log().contains("probe:quit"))
            check("quit: nothing is left to undo", real.undoTop == nil && real.undoLast() == nil)

            // Every window ends after 5 seconds
            hover.setOpen(true)
            await wait(100)
            sent.payloads = []
            card.discard(store.list.rows[4].key)
            hover.crossOffMain()
            real.completeHeld(key: real.list.rows[0].key, expected: nil, source: EventSource.notch)
            await wait(500)
            check("windows: the newest shows, the cross off", model.discarded?.kind == .done && model.discarded?.task.ref == "probe:ship")
            // Wide margins: the probes share the machine with a build, and the window rule itself is
            // a pure check in main-thing-checks.
            await wait(3000)
            check("windows: at 3.5s both are still held, no done went out", store.undo.entries.count == 2 && !sent.events.contains(.taskCompleted) && dones() == 1)
            await wait(2400)
            check("windows: after 5s the Undo is gone", model.discarded == nil && store.undo.isEmpty && titles.count == 3)
            check("windows: the cross off committed once, with its ref, from the notch",
                  sent.payloads.filter { $0.event == .taskCompleted }.map { $0.task?.ref } == ["probe:ship"] && sent.payloads.last?.source == EventSource.notch)
            check("windows: the discard sent nothing when its window ended", sent.events == [.listChanged, .listChanged, .taskCompleted])
            await wait(300)
            check("windows: the real store's done hook ran when its window ended", dones() == 2)
            try? fm.removeItem(at: root)
        }
        func finish() {
            try? FileManager.default.removeItem(at: silent)
            print("probe: " + (failures == 0 ? "all card checks passed" : "\(failures) failed"))
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }
}
