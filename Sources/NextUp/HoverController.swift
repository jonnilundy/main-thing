import AppKit
import NextUpCore
import Observation
import os

/// Opens and closes the notch from cursor moves, and decides click through.
/// The rules are in `NotchHover`; this class only wires them to AppKit.
@MainActor
final class HoverController {
    private let panel: NSPanel
    private let model: NotchModel
    private let store: TaskStore
    private let log = Logger(subsystem: NextUpBundleID, category: "hover")
    private var monitors: [Any] = []
    private var pendingOpen: Task<Void, Never>?

    init(panel: NSPanel, model: NotchModel, store: TaskStore) {
        self.panel = panel
        self.model = model
        self.store = store
    }

    func start() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        })
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.evaluate() }
            return event
        })
        monitors = [global, local].compactMap { $0 }
        observeList()
        evaluate()
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
            self?.evaluate()
        }
    }

    /// Runs on every cursor move.
    func evaluate() {
        if model.forceOpen {
            if !model.isOpen { setOpen(true) }
            panel.ignoresMouseEvents = false
            return
        }
        let inside = cursorInside()
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
        let point = NotchHover.panelPoint(screenPoint: NSEvent.mouseLocation, panelFrame: panel.frame)
        return NotchHover.inside(point, shape: model.shapeRect, isOpen: model.isOpen)
    }

    func setOpen(_ open: Bool) {
        guard model.isOpen != open else { return }
        model.isOpen = open
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
