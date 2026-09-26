import AppKit
import MainThingCore
import SwiftUI
import os

/// The open card's pointer: the one hover tracker for every row, and every press on the card.
///
/// Hover: `HoverController.evaluate` hands in each cursor move; the point maps to a slot
/// (`CardMap`) and lands in `NotchModel.hover`, the only hover state the rows draw. Presses: a
/// local monitor sees mouse down, drag and up in the notch panel and classifies them
/// (`CardPress`). A click crosses a task off, restores a discarded one, or opens the add card. A
/// drag from a task's number or dot reorders. A long press opens the Rename and Discard menu. The
/// rows are plain views with no gestures or buttons of their own, so a press means one thing.
///
/// Every edit is a `replace` on the store with source `notch`, the path the API takes. Edits go by
/// row key, so a list the API changed meanwhile still gets them on the right task.
@MainActor
final class CardController {
    private let model: NotchModel
    private let store: TaskStore
    private let panel: NSPanel
    private let toggle: (TaskList.Row) -> Void
    private let log = Logger(subsystem: MainThingBundleID, category: "card")
    private var monitor: Any?
    private var resignObserver: (any NSObjectProtocol)?
    private var press: CardPress?
    /// A press on the open menu, and the item it went down on.
    private var menuPress: RowMenu.Item??
    private var hold: Task<Void, Never>?
    private var undoExpiry: Task<Void, Never>?
    private var quietEnd: Task<Void, Never>?
    /// A field may take the keyboard. The probe turns this off, so it never takes typing from the
    /// app in front.
    var takesKeyboard = true
    /// The clock, for the Undo's 4 seconds.
    var now: () -> TimeInterval = { Date.timeIntervalSinceReferenceDate }

    init(model: NotchModel, store: TaskStore, panel: NSPanel, toggle: @escaping (TaskList.Row) -> Void) {
        self.model = model
        self.store = store
        self.panel = panel
        self.toggle = toggle
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var spring: Animation? { reduceMotion ? nil : Motion.openSpring }

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        // A click in another app takes the keyboard back: the field keeps what was typed, as
        // Finder does with a rename.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endFields(commit: true) }
        }
    }

    // MARK: Where the pointer is

    /// The card as it is laid out now.
    var map: CardMap { CardMap(model: model, store: store) }

    /// A panel point (origin top left) in card coordinates: y from the card's top, x from the body edge.
    func cardPoint(_ panelPoint: CGPoint) -> CGPoint {
        CGPoint(x: panelPoint.x - model.shapeRect.minX - NotchGeometry.flare, y: panelPoint.y - model.shapeRect.minY)
    }

    /// The key a slot holds, for the haptics: a row's key, or "add" and "undo".
    private func key(for slot: CardSlot) -> String? {
        switch slot {
        case .task(let index): store.list.key(at: index)
        case .undo: "undo"
        case .add: "add"
        case .none: nil
        }
    }

    private func slot(ofKey key: String) -> CardSlot {
        store.list.rows.firstIndex { $0.key == key }.map(CardSlot.task) ?? .none
    }

    /// Every cursor move the app sees, in panel coordinates; nil when the cursor is off the card
    /// or the card is closed. The one hover tracker.
    func pointer(at panelPoint: CGPoint?) {
        guard let panelPoint, model.isOpen else {
            if model.adding, model.addText.trimmingCharacters(in: .whitespaces).isEmpty { closeAdd() }
            if model.drag == nil { model.setHover(.none, key: nil, animated: !reduceMotion) }
            return
        }
        // A held task is lifted on its own; nothing else lights up under it.
        if model.drag != nil { return }
        let p = cardPoint(panelPoint)
        if var menu = model.menu {
            // The menu's row stays lit while the menu is up; its items light under the pointer.
            let item = RowMenu.item(at: p, in: menu.frame)
            if item != menu.hovered {
                menu.hovered = item
                withAnimation(reduceMotion ? nil : Motion.preview) { model.menu = menu }
            }
            let slot = slot(ofKey: menu.key)
            model.setHover(slot, key: key(for: slot), animated: !reduceMotion)
            return
        }
        let slot = map.slot(atY: p.y)
        model.setHover(slot, key: key(for: slot), animated: !reduceMotion)
    }

    // MARK: Presses

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: down(event)
        case .leftMouseDragged: dragged(event)
        case .leftMouseUp: up(event)
        default: break
        }
    }

    /// The event's position in card coordinates. Events in the panel carry their own window
    /// position, synthesized ones included.
    private func point(of event: NSEvent) -> CGPoint {
        let inWindow = event.locationInWindow
        return cardPoint(CGPoint(x: inWindow.x, y: panel.frame.height - inWindow.y))
    }

    private func down(_ event: NSEvent) {
        press = nil
        menuPress = nil
        hold?.cancel()
        // Control click is the right click menu.
        guard event.window === panel, model.isOpen, !event.modifierFlags.contains(.control) else { return }
        let p = point(of: event)
        let slot = map.slot(atY: p.y)
        if let menu = model.menu {
            // On the menu: its item acts on the release. Anywhere else: the menu goes, nothing more.
            if menu.frame.contains(p) {
                menuPress = .some(RowMenu.item(at: p, in: menu.frame))
            } else {
                dismissMenu()
            }
            return
        }
        // A field takes its own presses. A press anywhere else ends it (saving what it holds) and
        // then does what it does there, as a click past a rename in Finder does.
        if let field = fieldSlot {
            if field == slot { return }
            endFields(commit: true)
        }
        press = CardPress(slot: slot, start: p, onHandle: CardMap.inHandle(x: p.x))
        model.pressed = slot
        if case .task = slot {
            let wait = CardPress.longPressDuration(doubleClickInterval: NSEvent.doubleClickInterval)
            hold = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.longPress()
            }
        }
    }

    private func dragged(_ event: NSEvent) {
        let p = point(of: event)
        if menuPress != nil { return }
        guard var press else { return }
        let before = press.kind
        press.move(to: p)
        self.press = press
        switch press.kind {
        case .pressed:
            break
        case .moved:
            hold?.cancel()
            model.pressed = .none
        case .reordering:
            if before != .reordering {
                hold?.cancel()
                beginDrag(press)
            }
            moveDrag(offset: press.offset.height)
        case .longPressed:
            // Press, hold, slide onto an item: it lights, and the release picks it.
            if var menu = model.menu {
                let item = RowMenu.item(at: p, in: menu.frame)
                if item != menu.hovered {
                    menu.hovered = item
                    withAnimation(reduceMotion ? nil : Motion.preview) { model.menu = menu }
                }
            }
        }
    }

    private func up(_ event: NSEvent) {
        hold?.cancel()
        let p = point(of: event)
        if let pressed = menuPress {
            menuPress = nil
            if let menu = model.menu, let item = RowMenu.item(at: p, in: menu.frame), item == pressed {
                choose(item, on: menu.key)
            }
            return
        }
        guard let press else { return }
        self.press = nil
        model.pressed = .none
        switch press.kind {
        case .pressed:
            if let slot = press.click { click(slot) }
        case .reordering:
            endDrag()
        case .longPressed:
            // Released on an item after sliding onto it: that item. Else the menu stays for a click.
            if let menu = model.menu, let item = RowMenu.item(at: p, in: menu.frame) {
                choose(item, on: menu.key)
            }
        case .moved:
            break
        }
    }

    private func click(_ slot: CardSlot) {
        switch slot {
        case .task(let index):
            guard store.list.rows.indices.contains(index) else { return }
            toggle(store.list.rows[index])
        case .undo:
            undo()
        case .add:
            openAdd()
        case .none:
            break
        }
    }

    // MARK: Long press menu

    /// The press was held still long enough: the menu opens on its task, with a firm tick.
    private func longPress() {
        guard var press, press.held(), case .task(let index) = press.slot, let key = store.list.key(at: index) else { return }
        self.press = press
        model.pressed = .none
        let frame = RowMenu.frame(pressX: press.start.x, rowCenterY: map.centerY(of: .task(index)), cardWidth: model.openWidth)
        withAnimation(reduceMotion ? Motion.reducedFade : Motion.popSpring) {
            model.menu = CardMenu(key: key, frame: frame, hovered: nil)
        }
        model.performer.perform(.levelChange, performanceTime: .now)
        log.notice("long press menu on row \(index + 1, privacy: .public)")
    }

    func dismissMenu() {
        guard model.menu != nil else { return }
        withAnimation(reduceMotion ? Motion.reducedFade : Motion.fade) { model.menu = nil }
    }

    func choose(_ item: RowMenu.Item, on key: String) {
        dismissMenu()
        switch item {
        case .rename: startRename(key)
        case .discard: discard(key)
        }
    }

    // MARK: Reorder

    private func beginDrag(_ press: CardPress) {
        guard case .task(let index) = press.slot, let key = store.list.key(at: index) else { return }
        model.pressed = .none
        model.setHover(.none, key: nil, animated: false)
        withTransaction(Transaction(animation: nil)) {
            model.drag = CardDrag(key: key, from: index, target: index, offset: 0)
        }
        log.notice("reorder started on row \(index + 1, privacy: .public)")
    }

    /// The held task follows the pointer 1:1; when it passes the middle of another place, the
    /// others spring out of the way and a light tick marks the new place.
    private func moveDrag(offset: CGFloat) {
        guard var drag = model.drag else { return }
        let target = Reorder.target(from: drag.from, offset: offset, centers: map.liveCenters)
        drag.offset = offset
        if target != drag.target {
            drag.target = target
            withAnimation(spring) { model.drag = drag }
            model.performer.perform(.alignment, performanceTime: .now)
        } else {
            withTransaction(Transaction(animation: nil)) { model.drag = drag }
        }
    }

    /// The release: the list saves in the new order, and the held task settles into its place
    /// from where the pointer left it. A task dropped on top is the main thing; the old one is 2.
    private func endDrag() {
        guard let drag = model.drag else { return }
        let centers = map.liveCenters
        guard let tasks = store.list.moving(key: drag.key, to: drag.target) else {
            withAnimation(spring) { model.drag = nil }
            return
        }
        let residual = centers[drag.from] + drag.offset - centers[drag.target]
        quiet()
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            store.replace(tasks, source: EventSource.notch)
            model.drag = CardDrag(key: drag.key, from: drag.target, target: drag.target, offset: residual)
        }
        // The new order lands where everything already shows; then the held task springs home.
        panel.contentView?.layoutSubtreeIfNeeded()
        withAnimation(spring) { model.drag = nil }
        log.notice("reorder: row \(drag.from + 1, privacy: .public) to \(drag.target + 1, privacy: .public)")
    }

    /// Rows come and go without their transitions for a moment: a reorder or a rename is the
    /// same task in a new place or with a new title, not one leaving and one arriving.
    private func quiet() {
        model.quietRows = true
        quietEnd?.cancel()
        quietEnd = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.model.quietRows = false
        }
    }

    // MARK: Fields

    /// The slot whose field is open, if one is.
    private var fieldSlot: CardSlot? {
        if let key = model.renaming { return slot(ofKey: key) }
        if model.adding { return .add }
        return nil
    }

    /// The panel takes the keyboard for a field; non-activating, so the app in front stays in front.
    private func takeKeyboard() {
        guard takesKeyboard else { return }
        (panel as? NotchPanel)?.allowsKey = true
        panel.makeKey()
    }

    /// No field left: the keyboard goes back to the app in front. `resignKey` hands the key focus
    /// back without hiding the panel. Ordering it out and in did too, but left the notch off the
    /// screen for about 250ms.
    private func releaseKeyboard() {
        guard model.renaming == nil, !model.adding else { return }
        (panel as? NotchPanel)?.allowsKey = false
        guard panel.isKeyWindow else { return }
        panel.resignKey()
        log.notice("keyboard handed back")
    }

    func startRename(_ key: String) {
        guard let row = store.list.rows.first(where: { $0.key == key }) else { return }
        model.renameText = row.title
        model.renaming = key
        if model.adding { closeAdd() }
        takeKeyboard()
        log.notice("rename started")
    }

    /// Return: the new title lands on the task by its key. A blank title keeps the old one.
    func submitRename() {
        guard let key = model.renaming else { return }
        let text = model.renameText
        let tasks = store.list.renaming(key: key, to: text)
        model.renaming = nil
        model.renameText = ""
        if let tasks {
            quiet()
            store.replace(tasks, source: EventSource.notch)
            log.notice("renamed")
        }
        releaseKeyboard()
    }

    /// Escape, or the task went away: the title stays as it was.
    func cancelRename() {
        guard model.renaming != nil else { return }
        model.renaming = nil
        model.renameText = ""
        releaseKeyboard()
    }

    func openAdd() {
        guard !model.adding else { return }
        model.addText = ""
        withAnimation(reduceMotion ? Motion.reducedFade : Motion.fade) { model.adding = true }
        if model.renaming != nil { submitRename() }
        takeKeyboard()
    }

    /// Return: the task goes to the end of the list, and the field empties for another.
    func submitAdd() {
        guard let tasks = store.list.appending(model.addText) else { return }
        model.addText = ""
        store.replace(tasks, source: EventSource.notch)
        log.notice("added a task")
    }

    /// Escape, or the pointer left with the field empty.
    func closeAdd() {
        guard model.adding else { return }
        model.addText = ""
        withAnimation(reduceMotion ? Motion.reducedFade : Motion.fade) { model.adding = false }
        releaseKeyboard()
    }

    /// A press elsewhere, or the keyboard went to another app: a rename keeps its new title, a
    /// new task with text is added.
    func endFields(commit: Bool) {
        if model.renaming != nil { commit ? submitRename() : cancelRename() }
        if model.adding {
            if commit { submitAdd() }
            closeAdd()
        }
    }

    // MARK: Discard and Undo

    /// Deletes the task: no done hook, no adapter, no sound. An Undo shows in its place for 4 seconds.
    func discard(_ key: String) {
        guard let (tasks, gone) = store.list.discarding(key: key, at: now()) else { return }
        if model.renaming == key { cancelRename() }
        withAnimation(reduceMotion ? Motion.reducedFade : Motion.content(false)) {
            model.discarded = gone
            store.replace(tasks, source: EventSource.notch)
        }
        undoExpiry?.cancel()
        undoExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Discarded.seconds))
            guard let self, !Task.isCancelled, let shown = self.model.discarded, shown == gone, shown.expired(at: self.now()) else { return }
            withAnimation(self.reduceMotion ? Motion.reducedFade : Motion.fade) { self.model.discarded = nil }
        }
        log.notice("discarded row \(gone.index + 1, privacy: .public)")
    }

    /// Puts the discarded task back where it was.
    func undo() {
        guard let gone = model.discarded else { return }
        undoExpiry?.cancel()
        withAnimation(reduceMotion ? Motion.reducedFade : Motion.content(false)) {
            model.discarded = nil
            store.replace(gone.restored(into: store.list.tasks), source: EventSource.notch)
        }
        log.notice("undo: row \(gone.index + 1, privacy: .public) back")
    }

    // MARK: The list and the card

    /// The list changed, from here or through the API. A rename, menu or drag whose task is gone
    /// ends; a rename whose task is still there keeps its text for that task.
    func listChanged() {
        let keys = Set(store.list.rows.map(\.key))
        if let key = model.renaming, !keys.contains(key) {
            log.notice("rename dropped: the task left the list")
            cancelRename()
        }
        if let menu = model.menu, !keys.contains(menu.key) { dismissMenu() }
        if press?.kind == .reordering, let drag = model.drag,
           store.list.rows.firstIndex(where: { $0.key == drag.key }) != drag.from {
            // The list moved under a held task: let go of it rather than drop it in a wrong place.
            press = nil
            withAnimation(spring) { model.drag = nil }
        }
    }

    /// The card closed: no hover, no press, no menu; fields and the Undo end.
    func closed() {
        press = nil
        menuPress = nil
        hold?.cancel()
        model.pressed = .none
        model.menu = nil
        model.drag = nil
        cancelRename()
        closeAdd()
        undoExpiry?.cancel()
        model.discarded = nil
        model.setHover(.none, key: nil, animated: false)
    }
}

extension CardMap {
    /// The open card as the model and the store lay it out now.
    @MainActor init(model: NotchModel, store: TaskStore) {
        let notes = (model.apiBound ? 0 : 1) + store.events.failing.count
        self.init(
            notchHeight: model.geometry.notchHeight,
            taskCount: store.list.count,
            undoRow: model.discarded?.undoRow,
            notesHeight: CGFloat(notes) * (OpenLayout.noteSpacing + OpenLayout.noteHeight),
            rowsMax: model.rowsMaxHeight,
            scroll: model.rowsScroll,
            addOpen: model.hover == .add || model.adding
        )
    }
}
