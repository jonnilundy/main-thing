import AppKit
import NextUpCore
import Observation
import os

/// Opens and closes the notch from cursor moves, and decides click through.
/// The rules are in `NotchHover`; this class only wires them to AppKit.
///
/// Cursor moves arrive three ways: a global monitor while the panel ignores events,
/// a tracking area on the hosting view while it accepts them, and a local monitor as
/// a backstop. Each carries the event's own location, because `NSEvent.mouseLocation`
/// can still report the old position inside the handler for a warped cursor.
@MainActor
final class HoverController {
    private let panel: NSPanel
    private let model: NotchModel
    private let store: TaskStore
    private let log = Logger(subsystem: NextUpBundleID, category: "hover")
    private var monitors: [Any] = []
    private var pendingOpen: Task<Void, Never>?
    /// Last cursor position seen in an event, AppKit screen coordinates.
    private var lastScreenPoint: CGPoint

    init(panel: NSPanel, model: NotchModel, store: TaskStore) {
        self.panel = panel
        self.model = model
        self.store = store
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

    /// Runs on every cursor move, with the position the event carried.
    func evaluate(at screenPoint: CGPoint, source: String) {
        lastScreenPoint = screenPoint
        if model.forceOpen {
            if !model.isOpen { setOpen(true) }
            panel.ignoresMouseEvents = false
            return
        }
        let point = NotchHover.panelPoint(screenPoint: screenPoint, panelFrame: panel.frame)
        let inside = NotchHover.inside(point, shape: model.shapeRect, isOpen: model.isOpen)
        log.debug("\(source, privacy: .public) screen (\(Int(screenPoint.x), privacy: .public),\(Int(screenPoint.y), privacy: .public)) panel (\(Int(point.x), privacy: .public),\(Int(point.y), privacy: .public)) shape \(NSStringFromRect(self.model.shapeRect), privacy: .public) inside \(inside, privacy: .public) open \(self.model.isOpen, privacy: .public)")
        panel.ignoresMouseEvents = !inside
        switch NotchHover.intent(isOpen: model.isOpen, pendingOpen: pendingOpen != nil, inside: inside) {
        case .scheduleOpen:
            pendingOpen = Task { @MainActor [weak self] in
                try? await Task.sleep(for: NotchHover.openDelay)
                guard let self, !Task.isCancelled else { return }
                self.pendingOpen = nil
                if self.cursorInside() { self.setOpen(true) }
            }
        case .cancelOpen:
            pendingOpen?.cancel()
            pendingOpen = nil
        case .close:
            setOpen(false)
        case .none:
            break
        }
    }

    private func cursorInside() -> Bool {
        let point = NotchHover.panelPoint(screenPoint: lastScreenPoint, panelFrame: panel.frame)
        return NotchHover.inside(point, shape: model.shapeRect, isOpen: model.isOpen)
    }

    func setOpen(_ open: Bool) {
        guard model.isOpen != open else { return }
        model.isOpen = open
        log.notice("open = \(open, privacy: .public) at screen (\(Int(self.lastScreenPoint.x), privacy: .public),\(Int(self.lastScreenPoint.y), privacy: .public))")
        if !open { model.doneArmed = false }
    }

    /// The done circle. Fills for 250ms, then completes the task the button showed.
    func completeCurrent() {
        guard !model.doneArmed, let title = store.current else { return }
        model.doneArmed = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.store.complete(expected: title)
            self.model.doneArmed = false
            self.refresh()
        }
    }
}
