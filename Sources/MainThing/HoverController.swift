import AppKit
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

    init(panel: NSPanel, model: NotchModel, store: TaskStore, layout: PanelLayout, sounds: Sounds) {
        self.panel = panel
        self.model = model
        self.store = store
        self.layout = layout
        self.sounds = sounds
        self.lastScreenPoint = NSEvent.mouseLocation
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
        if model.editorOpen {
            // The editor holds the list: no opening on hover, no clicks on the notch.
            panel.ignoresMouseEvents = true
            if model.isOpen { setOpen(false) }
            return
        }
        if model.forceOpen {
            if !model.isOpen { setOpen(true) }
            panel.ignoresMouseEvents = false
            return
        }
        let point = NotchHover.panelPoint(screenPoint: screenPoint, panelFrame: panel.frame)
        let inside = NotchHover.inside(point, shape: model.shapeRect, isOpen: model.isOpen)
        log.debug("\(source, privacy: .public) screen (\(Int(screenPoint.x), privacy: .public),\(Int(screenPoint.y), privacy: .public)) panel (\(Int(point.x), privacy: .public),\(Int(point.y), privacy: .public)) shape \(NSStringFromRect(self.model.shapeRect), privacy: .public) inside \(inside, privacy: .public) open \(self.model.isOpen, privacy: .public)")
        panel.ignoresMouseEvents = !inside
        switch NotchHover.intent(isOpen: model.isOpen, inside: inside) {
        case .open: setOpen(true)
        case .close: setOpen(false)
        case .none: break
        }
    }

    func setOpen(_ open: Bool) {
        guard model.isOpen != open else { return }
        // The panel grows before the shape animates, so nothing is clipped on the way up.
        if open {
            layout.fitOpen()
            sounds.wake()
        } else {
            sounds.rest()
        }
        model.isOpen = open
        model.rowsAnimate()
        log.notice("open = \(open, privacy: .public) at screen (\(Int(self.lastScreenPoint.x), privacy: .public),\(Int(self.lastScreenPoint.y), privacy: .public))")
        if !open {
            model.pending = PendingCompletions()
            layout.fitClosed()
        }
    }

    /// The editor window came up: collapse now, whatever the cursor is on.
    func editorOpened() {
        panel.ignoresMouseEvents = true
        setOpen(false)
    }

    /// The list changed while open: rows that left are no longer pending, and the card refits.
    func listChanged() {
        model.pending.keep(only: Set(store.list.rows.map(\.key)))
        model.rowsAnimate()
        if model.isOpen { layout.fitOpen() }
    }

    /// A click on a row. The row is struck through at once, with a haptic tick; after
    /// `completionDelay` it leaves, and that removal is the completion: events and the adapter run
    /// for that task then, not before. A second click inside the window restores the row and
    /// nothing is sent anywhere.
    func toggleCompletion(of row: TaskList.Row) {
        switch model.pending.toggle(row.key) {
        case .cancelled:
            log.notice("cross off cancelled: \(row.title, privacy: .private)")
            sounds.unscratch()
        case .armed:
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            log.notice("stroke start: \(row.title, privacy: .private)")
            sounds.scratch(lines: 1)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: HoverController.completionDelay)
                guard let self, self.model.pending.finish(row.key) else { return }
                self.store.complete(key: row.key, expected: row.title, source: EventSource.notch)
                self.refresh()
            }
        }
    }
}
