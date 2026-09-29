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
/// Keys: while the card has the keyboard from a shortcut (Show list, Add task) and no field is
/// open, a local monitor maps each key press (`CardKeys`) to the same edits the pointer makes. The
/// keyboard highlight is `NotchModel.hover`, the pointer's own highlight: the last input wins.
///
/// Every edit is a `replace` on the store with source `notch`, the path the API takes. Edits go by
/// row key, so a list the API changed meanwhile still gets them on the right task. A cross off and
/// a discard go through the store's undo stack: the Undo row shows the newest one.
@MainActor
final class CardController {
    private let model: NotchModel
    private let store: TaskStore
    private let panel: NSPanel
    private let toggle: (TaskList.Row) -> Void
    private let log = Logger(subsystem: MainThingBundleID, category: "card")
    private var monitor: Any?
    private var keyMonitor: Any?
    private var resignObserver: (any NSObjectProtocol)?
    private var press: CardPress?
    /// A press on the open menu, and the item it went down on.
    private var menuPress: RowMenu.Item??
    private var hold: Task<Void, Never>?
    private var quietEnd: Task<Void, Never>?
    /// A field may take the keyboard. The probe turns this off, so it never takes typing from the
    /// app in front.
    var takesKeyboard = true
    /// The link sound's player: the app's own, set at launch before the card is made. The bench
    /// and the probe never set it, so their links resolve without a sound.
    var sounds: Sounds? = SettingsWindow.sounds
    /// The New task field closed: a card the Add task shortcut opened can close with it.
    var onAddClosed: (() -> Void)?
    /// Escape with no field open while the card has the keyboard: close the card.
    var onEscape: (() -> Void)?
    /// The panel lost the keyboard to another app while the card had it.
    var onKeyboardLost: (() -> Void)?
    /// The card has the keyboard from a shortcut: keys move the highlight and act on it. Opening
    /// the card with the pointer never takes the keyboard.
    private(set) var keyboardControl = false
    /// The highlight came from a key. The pointer takes it back once it moves, not before: a list
    /// change re-reads a still pointer, and that must not move the highlight.
    private(set) var keyHighlight = false
    /// Where the pointer was (screen) at the last key, and where it is now.
    private var keyAnchor: CGPoint?
    private var lastScreenPoint: CGPoint?
    /// Set while an edit here changes the undo stack: the Undo row changes in the edit's own
    /// animation, not in a fade of its own.
    private var editing = false

    init(model: NotchModel, store: TaskStore, panel: NSPanel, toggle: @escaping (TaskList.Row) -> Void) {
        self.model = model
        self.store = store
        self.panel = panel
        self.toggle = toggle
        // A resolved link is the same row with a new key: swap it in place, no leave and enter.
        store.willRekey = { [weak self] old, new in
            self?.quiet()
            self?.model.rekey(from: old, to: new)
            self?.sparkle(new)
            self?.sounds?.linkResolved()
        }
        store.onUndoChange = { [weak self] in self?.syncUndo() }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var spring: Animation? { reduceMotion ? nil : Motion.openSpring }

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.key(event) ?? false }
            return used ? nil : event
        }
        // A click in another app takes the keyboard back: the field keeps what was typed, as
        // Finder does with a rename.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardTaken() }
        }
    }

    private func keyboardTaken() {
        let had = keyboardControl
        keyboardControl = false
        keyHighlight = false
        endFields(commit: true)
        releaseKeyboard()
        if had { onKeyboardLost?() }
    }

    // MARK: Where the pointer is

    /// The card as it is laid out now.
    var map: CardMap { CardMap(model: model, store: store) }
    /// The last pointer position in card coordinates, and where it was when a row was added.
    private var lastPointer: CGPoint?
    private var quietPreviewFrom: CGPoint?

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

    /// Every cursor position the app sees, screen coordinates, before `pointer(at:)`. A pointer
    /// that moved since the last key takes the highlight back.
    func notePointer(screen point: CGPoint) {
        lastScreenPoint = point
        guard keyHighlight else { return }
        if let anchor = keyAnchor, hypot(point.x - anchor.x, point.y - anchor.y) <= 2 { return }
        keyHighlight = false
    }

    private func slot(ofKey key: String) -> CardSlot {
        store.list.rows.firstIndex { $0.key == key }.map(CardSlot.task) ?? .none
    }

    /// Every cursor move the app sees, in panel coordinates; nil when the cursor is off the card
    /// or the card is closed. The one hover tracker.
    func pointer(at panelPoint: CGPoint?) {
        guard let panelPoint, model.isOpen else {
            if model.adding, model.addText.trimmingCharacters(in: .whitespaces).isEmpty { closeAdd() }
            if model.drag == nil, !keyHighlight { model.setHover(.none, key: nil, animated: !reduceMotion) }
            return
        }
        // The keyboard has the highlight until the pointer moves.
        if keyHighlight { return }
        // A held task is lifted on its own; nothing else lights up under it.
        if model.drag != nil { return }
        let p = cardPoint(panelPoint)
        lastPointer = p
        if model.quietPreviewKey != nil, let from = quietPreviewFrom, hypot(p.x - from.x, p.y - from.y) > 3 {
            model.quietPreviewKey = nil
        }
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
        // A click gives the card the keyboard, as a click in any window does: Command Z then undoes
        // the cross off it made, and the keys work. It goes back when the card closes.
        if !keyboardControl { takeKeyboardControl() }
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
                let item = RowMenu.releaseItem(at: p, pressedAt: press.start, in: menu.frame)
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
            if let menu = model.menu, let item = RowMenu.releaseItem(at: p, pressedAt: press.start, in: menu.frame) {
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
        let frame = RowMenu.frame(rowCenterY: map.centerY(of: .task(index)), cardWidth: model.openWidth)
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

    /// The row of a resolved link sparkles once. The flag goes when the sparkle is over, so the
    /// row stops redrawing.
    private func sparkle(_ key: String) {
        guard !reduceMotion else { return }
        let sparkle = NotchModel.Sparkle(key: key, start: Date())
        model.sparkle = sparkle
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(SparkleBurst.duration * 1000) + 50))
            if self?.model.sparkle == sparkle { self?.model.sparkle = nil }
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
        guard model.renaming == nil, !model.adding, !keyboardControl else { return }
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
    /// Return: the typed text becomes the new last row right where it was, and the empty field
    /// shows under it, in one frame. No entrance for the row and no slide for the field: with them
    /// the field emptied first and the row faded in over it while the field slid away.
    func submitAdd() {
        guard let tasks = store.list.appending(model.addText) else { return }
        quiet()
        var swap = Transaction()
        swap.disablesAnimations = true
        withTransaction(swap) {
            model.addText = ""
            store.replace(tasks, source: EventSource.notch)
        }
        // The new row lands under the pointer, which did not move to it: no hover line on it yet.
        model.quietPreviewKey = store.list.rows.last?.key
        quietPreviewFrom = lastPointer
        log.notice("added a task")
    }

    /// Escape, or the pointer left with the field empty.
    func closeAdd() {
        guard model.adding else { return }
        model.addText = ""
        withAnimation(reduceMotion ? Motion.reducedFade : Motion.fade) { model.adding = false }
        releaseKeyboard()
        onAddClosed?()
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

    // MARK: Cross off, discard and Undo

    /// A cross off whose pen stroke is done: the row leaves and an Undo shows in its place for 5
    /// seconds. The done hook and the adapter run when that window ends (`TaskStore.completeHeld`).
    @discardableResult
    func completeHeld(key: String, expected: String?) -> Bool {
        edit { store.completeHeld(key: key, expected: expected, source: EventSource.notch) != nil }
    }

    /// Deletes the task: no done hook, no adapter, no sound. An Undo shows in its place for 5 seconds.
    func discard(_ key: String) {
        if model.renaming == key { cancelRename() }
        edit { store.discard(key: key, source: EventSource.notch) != nil }
    }

    /// Command Z, the Undo row, or the Undo shortcut: a pen stroke still drawing is kept, as a
    /// second click keeps it; else the newest cross off or discard in its window comes back where
    /// it was. With the card closed the task just returns to the list.
    func undo() {
        if let key = model.pending.keys.last, let row = store.list.rows.first(where: { $0.key == key }) {
            toggle(row)
            return
        }
        edit { store.undoLast() != nil }
    }

    /// A store edit that changes the undo stack, in one animation with the Undo row.
    @discardableResult
    private func edit(_ change: () -> Bool) -> Bool {
        editing = true
        defer { editing = false }
        var changed = false
        withAnimation(reduceMotion ? Motion.reducedFade : Motion.content(false)) { changed = change() }
        return changed
    }

    /// The Undo row shows the store's newest entry. A window that ran out fades it.
    private func syncUndo() {
        let top = store.undoTop
        guard model.discarded != top else { return }
        if editing {
            model.discarded = top
        } else {
            withAnimation(reduceMotion ? Motion.reducedFade : Motion.fade) { model.discarded = top }
        }
    }

    // MARK: Keys

    /// A shortcut opened the card: it takes the keyboard, and keys work until it closes.
    func takeKeyboardControl() {
        keyboardControl = true
        takeKeyboard()
    }

    /// A key press in the panel. True when the card used it; the monitor then drops it.
    private func key(_ event: NSEvent) -> Bool {
        guard keyboardControl, model.isOpen, event.window === panel else { return false }
        // A field takes its own keys: Return saves or adds, Escape closes it, Command Z undoes typing.
        if fieldSlot != nil { return false }
        let modifiers = KeyModifiers(event.modifierFlags)
        guard let action = CardKeys.action(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: modifiers) else {
            // Command shortcuts go on (Command comma opens Settings); other keys would only beep.
            return !modifiers.contains(.command) && !modifiers.contains(.control)
        }
        perform(action)
        return true
    }

    /// What a key does, on the highlighted slot.
    func perform(_ action: CardKey) {
        if model.menu != nil {
            dismissMenu()
            if action == .escape { return }
        }
        let rows = store.list.rows
        let highlighted: TaskList.Row? = {
            guard case .task(let index) = model.hover, rows.indices.contains(index) else { return nil }
            return rows[index]
        }()
        switch action {
        case .step(let by):
            highlight(CardKeys.step(from: model.hover, by: by, taskCount: rows.count, wraps: false))
        case .cycle(let by):
            highlight(CardKeys.step(from: model.hover, by: by, taskCount: rows.count, wraps: true))
        case .activate:
            if let highlighted {
                toggle(highlighted)
            } else if model.hover == .add {
                openAdd()
            } else if model.hover == .undo {
                undo()
            }
        case .rename:
            if let highlighted { startRename(highlighted.key) }
        case .discard:
            if let highlighted {
                discard(highlighted.key)
                highlight(CardKeys.clamp(model.hover, taskCount: store.list.count))
            }
        case .moveTask(let by):
            if let highlighted { move(highlighted.key, by: by) }
        case .newTask:
            highlight(.add)
            openAdd()
        case .undo:
            undo()
        case .escape:
            onEscape?()
        }
        log.notice("key: \(String(describing: action), privacy: .public)")
    }

    /// The keyboard highlight moves to `slot`, with the pointer's own look.
    private func highlight(_ slot: CardSlot) {
        keyHighlight = true
        keyAnchor = lastScreenPoint
        model.setHover(slot, key: nil, animated: !reduceMotion)
        let row: String? = switch slot {
        case .task(let index) where index > 0: store.list.key(at: index)
        case .add: store.list.rows.last?.key
        default: nil
        }
        if let row { model.scrollTarget = .init(key: row, serial: (model.scrollTarget?.serial ?? 0) + 1) }
    }

    /// Option Up or Down: the task moves one place, the store path a drag takes, and the highlight
    /// goes with it.
    private func move(_ key: String, by: Int) {
        guard let from = store.list.rows.firstIndex(where: { $0.key == key }) else { return }
        let to = min(max(from + by, 0), store.list.count - 1)
        guard let tasks = store.list.moving(key: key, to: to) else { return }
        quiet()
        withAnimation(spring) { store.replace(tasks, source: EventSource.notch) }
        highlight(.task(to))
        log.notice("reorder by key: row \(from + 1, privacy: .public) to \(to + 1, privacy: .public)")
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
        if keyHighlight {
            let clamped = CardKeys.clamp(model.hover, taskCount: store.list.count)
            if clamped != model.hover { model.setHover(clamped, key: nil, animated: false) }
        }
        if press?.kind == .reordering, let drag = model.drag,
           store.list.rows.firstIndex(where: { $0.key == drag.key }) != drag.from {
            // The list moved under a held task: let go of it rather than drop it in a wrong place.
            press = nil
            withAnimation(spring) { model.drag = nil }
        }
    }

    /// The card closed: no hover, no press, no menu; fields end and the keyboard goes back. An
    /// Undo keeps its window: Command Z is gone with the keyboard, the Undo shortcut still works.
    func closed() {
        press = nil
        menuPress = nil
        hold?.cancel()
        model.pressed = .none
        model.menu = nil
        model.drag = nil
        keyboardControl = false
        keyHighlight = false
        cancelRename()
        closeAdd()
        releaseKeyboard()
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
            addOpen: model.hover == .add || model.adding,
            bridged: model.geometry.bridgeRect != nil
        )
    }
}

extension KeyModifiers {
    /// The modifier keys of an NSEvent that a card key looks at.
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.control) { insert(.control) }
    }
}
