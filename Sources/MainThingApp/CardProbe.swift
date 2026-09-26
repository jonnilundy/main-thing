import AppKit
import MainThingCore
import SwiftUI

/// `MainThing --probe-card`: every edit in the open card, end to end, without the real cursor.
///
/// The real notch view, hover rules and card pointer run in an invisible panel (alpha 0, bottom
/// left of the main screen) on a list in memory: no tasks file is read or written, no hook runs,
/// no sound plays, and a counter stands in for the trackpad. Mouse events are built as NSEvents and
/// handed to the app's own `sendEvent`, the path real clicks take after the window server; no
/// CGEvent is posted and the cursor never moves. Fields never take the keyboard: the probe types by
/// setting the field's text. Prints one line per check and exits 1 when one fails.
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
            await wait(500)
            check("click: 400ms later the task leaves", !store.list.rows.contains(third))
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

            // Undo runs out after 4 seconds
            card.discard(store.list.rows[4].key)
            await wait(3800)
            check("Undo: still there at 3.8s", model.discarded != nil)
            await wait(500)
            check("Undo: gone after 4s, the task stays discarded", model.discarded == nil && titles.count == 4)
            store.replace(start, source: "probe")
            await wait(100)

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
            model.addText = "  "
            card.submitAdd()
            check("Add: a blank title adds nothing", titles.count == 6)
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
            finish()
        }
        func finish() {
            try? FileManager.default.removeItem(at: silent)
            print("probe: " + (failures == 0 ? "all card checks passed" : "\(failures) failed"))
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }
}
