import AppKit
import KeyboardShortcuts
import MainThingCore
import Observation
import os

/// Opens and closes the notch from cursor moves, decides click through, and runs row completions.
/// The rules are in `NotchHover`; this class only wires them to AppKit.
///
/// Cursor moves arrive three ways: a global monitor while the panel ignores events,
/// a tracking area on the hosting view while it accepts them, and a local monitor as
/// a backstop. Each carries the event's own location, because `NSEvent.mouseLocation`
/// can still report the old position inside the handler for a warped cursor.
@MainActor
final class HoverController {
    /// From the click to the row leaving: the strikethrough draws for 150ms, then 250ms more.
    static let completionDelay: Duration = .milliseconds(400)

    private let panel: NSPanel
    private let model: NotchModel
    private let store: TaskStore
    private let layout: PanelLayout
    private let sounds: Sounds
    private let log = Logger(subsystem: MainThingBundleID, category: "hover")
    private var monitors: [Any] = []
    /// Last cursor position seen in an event, AppKit screen coordinates.
    private var lastScreenPoint: CGPoint
    /// The open card's pointer: every move goes on to it, for the rows' hover.
    weak var card: CardController? {
        didSet {
            card?.onAddClosed = { [weak self] in self?.addFieldClosed() }
            card?.onEscape = { [weak self] in self?.keyEscape() }
            card?.onKeyboardLost = { [weak self] in self?.keyboardLost() }
        }
    }
    /// The card a shortcut opened, open off the shape until the pointer has been on it and left.
    private var pin: ShortcutPin?
    /// Escape as a hot key while Show list holds the card open: the app in front keeps the keyboard.
    private var escape: Task<Void, Never>?

    init(panel: NSPanel, model: NotchModel, store: TaskStore, layout: PanelLayout, sounds: Sounds) {
        self.panel = panel
        self.model = model
        self.store = store
        self.layout = layout
        self.sounds = sounds
        self.lastScreenPoint = NSEvent.mouseLocation
        // At quit the pen strokes still drawing are crossed off first, then everything held commits.
        store.beforeQuit = { [weak self] in self?.finishStrokes() }
    }

    func start() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.evaluate(at: HoverController.screenPoint(of: event), source: "global")
            }
        })
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.evaluate(at: HoverController.screenPoint(of: event), source: "local")
            }
            return event
        })
        monitors = [global, local].compactMap { $0 }
        // Undo, from any app. Registered here with the card it acts on; the other shortcuts are in
        // `AppDelegate.installShortcuts`.
        KeyboardShortcuts.onKeyDown(for: .undo) { [weak self] in self?.undoShortcut() }
        log.notice("monitors installed: global \(global != nil, privacy: .public) local \(local != nil, privacy: .public)")
        observeList()
        evaluate(at: NSEvent.mouseLocation, source: "start")
    }

    /// The event's position in AppKit screen coordinates.
    ///
    /// `locationInWindow` is not usable for this: a global monitor copy of an event over another
    /// app's window carries that window's coordinates with `window` nil, and synthesized enter
    /// and exit events carry garbage. The CGEvent location is always global (origin top left of
    /// the primary screen), so it is converted from there.
    static func screenPoint(of event: NSEvent) -> CGPoint {
        if let location = event.cgEvent?.location, let primary = NSScreen.screens.first {
            return CGPoint(x: location.x, y: primary.frame.maxY - location.y)
        }
        if let window = event.window {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return NSEvent.mouseLocation
    }

    /// A list change moves the shape, so a cursor that did not move can now be inside or outside.
    private func observeList() {
        withObservationTracking {
            _ = store.list
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observeList()
            }
        }
    }

    func refresh() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self else { return }
            self.evaluate(at: self.lastScreenPoint, source: "refresh")
        }
    }

    /// Runs on every cursor move, with the position the event carried. No delay: the first
    /// move inside the shape opens the notch.
    func evaluate(at screenPoint: CGPoint, source: String) {
        lastScreenPoint = screenPoint
        card?.notePointer(screen: screenPoint)
        if model.forceOpen {
            if !model.isOpen { setOpen(true) }
            setClickThrough(false)
            return
        }
        let point = NotchHover.panelPoint(screenPoint: screenPoint, panelFrame: panel.frame)
        let inside = NotchHover.inside(point, shape: model.shapeRect, bridge: model.geometry.bridgeRect, isOpen: model.isOpen)
        log.debug("\(source, privacy: .public) screen (\(Int(screenPoint.x), privacy: .public),\(Int(screenPoint.y), privacy: .public)) panel (\(Int(point.x), privacy: .public),\(Int(point.y), privacy: .public)) shape \(NSStringFromRect(self.model.shapeRect), privacy: .public) inside \(inside, privacy: .public) open \(self.model.isOpen, privacy: .public)")
        if var pin {
            if pin.holds(inside: inside) {
                self.pin = pin
                setClickThrough(!inside)
                if inside {
                    card?.pointer(at: point)
                } else if model.drag == nil, card?.keyHighlight != true {
                    // Not `card.pointer(at: nil)`: that closes an empty New task field.
                    model.setHover(.none, key: nil, animated: true)
                }
                return
            }
            log.notice("shortcut pin over: the pointer left the card")
            endPin()
        }
        setClickThrough(!inside)
        switch NotchHover.intent(isOpen: model.isOpen, inside: inside) {
        case .open: setOpen(true)
        // A held task, a rename, or a new task with text keeps the card open off the shape.
        case .close: if !model.holdsOpen { setOpen(false) }
        case .none: break
        }
        card?.pointer(at: inside ? point : nil)
    }

    /// Click through on or off, written only when it changes. Every write of `ignoresMouseEvents`,
    /// even of the value it already has, is a WindowServer event mask transaction plus a Core
    /// Animation commit: about 0.6ms of main thread per cursor move, twice per move while open.
    private func setClickThrough(_ ignores: Bool) {
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
    }

    func setOpen(_ open: Bool) {
        guard model.isOpen != open else { return }
        let started = ContinuousClock.now
        model.openStartedAt = open ? started : nil
        // The panel grows before the shape animates, so nothing is clipped on the way up.
        if open {
            layout.fitOpen()
            sounds.wake()
        } else {
            sounds.rest()
        }
        model.isOpen = open
        model.rowsAnimate()
        let took = (ContinuousClock.now - started).components
        let ms = Double(took.seconds) * 1000 + Double(took.attoseconds) / 1e15
        log.notice("open = \(open, privacy: .public) at screen (\(Int(self.lastScreenPoint.x), privacy: .public),\(Int(self.lastScreenPoint.y), privacy: .public)) in \(ms, format: .fixed(precision: 1), privacy: .public) ms")
        if !open {
            endPin()
            // A pen stroke still drawing is a cross off: it finishes now instead of being dropped.
            finishStrokes()
            card?.closed()
            layout.fitClosed()
        }
    }

    /// The list changed while open: rows that left are no longer pending, and the card refits.
    func listChanged() {
        model.pending.keep(only: Set(store.list.rows.map(\.key)))
        card?.listChanged()
        model.rowsAnimate()
        if model.isOpen { layout.fitOpen() }
    }

    /// A click on a row. The row is struck through at once, with a haptic tick; after
    /// `completionDelay` it leaves and an Undo shows in its place for 5 seconds. The done hook and
    /// the adapter run for that task when the Undo window ends, not before. A second click inside
    /// the pen stroke restores the row and nothing is sent anywhere.
    func toggleCompletion(of row: TaskList.Row) {
        switch model.pending.toggle(row.key) {
        case .cancelled:
            log.notice("cross off cancelled: \(row.title, privacy: .private)")
            sounds.unscratch()
        case .armed:
            model.performer.perform(.levelChange, performanceTime: .now)
            log.notice("stroke start: \(row.title, privacy: .private)")
            sounds.scratch(lines: 1)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: HoverController.completionDelay)
                guard let self, self.model.pending.finish(row.key) else { return }
                self.crossOff(key: row.key, expected: row.title)
            }
        }
    }

    /// The pen stroke is done: the row leaves into the undo stack.
    private func crossOff(key: String, expected: String?) {
        if let card {
            card.completeHeld(key: key, expected: expected)
        } else {
            store.completeHeld(key: key, expected: expected, source: EventSource.notch)
        }
        refresh()
    }

    /// Every pen stroke still drawing crosses its task off now: the card closes or the app quits.
    private func finishStrokes() {
        let keys = model.pending.keys
        model.pending = PendingCompletions()
        for key in keys { crossOff(key: key, expected: nil) }
    }

    // MARK: Shortcuts

    /// Show list: open the card and keep it open. Pressed again while it holds: close.
    func showList() {
        if pin != nil {
            log.notice("shortcut: show list again, closing")
            closePinned()
            return
        }
        log.notice("shortcut: show list")
        pinOpen(.list)
    }

    /// Add task: open the card with the New task field, the keyboard in it. Return and Escape
    /// work as in a field opened with a click; the card closes with the field.
    func addTask() {
        log.notice("shortcut: add task")
        pinOpen(.add)
        card?.openAdd()
    }

    /// Cross off task 1, as a click on it does: the pen, the sound, and a second press in the
    /// window keeps it.
    func crossOffMain() {
        guard let first = store.list.rows.first else {
            log.notice("shortcut: cross off, the list is empty")
            return
        }
        log.notice("shortcut: cross off main task")
        toggleCompletion(of: first)
    }

    /// Undo from any app: the newest cross off or discard still in its window comes back.
    func undoShortcut() {
        log.notice("shortcut: undo")
        if let card { card.undo() } else { store.undoLast() }
    }

    private func pinOpen(_ reason: ShortcutPin.Reason) {
        if pin == nil { pin = ShortcutPin(reason) } else { pin?.reason = reason }
        setOpen(true)
        // The card takes the keyboard: the arrows, Return and Escape reach it as keys. A Carbon
        // Escape hot key would swallow Escape before the card saw it.
        card?.takeKeyboardControl()
        listenForEscape(false)
        evaluate(at: NSEvent.mouseLocation, source: "shortcut")
    }

    private func endPin() {
        pin = nil
        listenForEscape(false)
    }

    /// The shortcut again, or Escape: a field keeps what it holds, as with a click elsewhere,
    /// and the card closes.
    private func closePinned() {
        endPin()
        card?.endFields(commit: true)
        setOpen(false)
    }

    /// Escape with no field open, while the card has the keyboard: the card closes.
    private func keyEscape() {
        log.notice("key: escape, closing")
        closePinned()
    }

    /// Another app took the keyboard while Show list holds the card: Escape goes back to being a
    /// hot key, so it still closes the card.
    private func keyboardLost() {
        if pin?.reason == .list { listenForEscape(true) }
    }

    /// The New task field closed (Escape, or a click in another app) while Add task held the card:
    /// the card stays only if the pointer is on it.
    private func addFieldClosed() {
        guard pin?.reason == .add else { return }
        endPin()
        evaluate(at: lastScreenPoint, source: "add closed")
    }

    private func listenForEscape(_ on: Bool) {
        guard on != (escape != nil) else { return }
        escape?.cancel()
        escape = nil
        guard on else { return }
        escape = Task { @MainActor [weak self] in
            for await _ in KeyboardShortcuts.events(.keyDown, for: .init(.escape)) {
                self?.escapePressed()
            }
        }
    }

    /// Escape as it works in the card: it ends a rename or a New task field first, then closes.
    private func escapePressed() {
        log.notice("shortcut: escape")
        if model.renaming != nil {
            card?.cancelRename()
        } else if model.adding {
            card?.closeAdd()
        } else {
            closePinned()
        }
    }
}
