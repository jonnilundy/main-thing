import AppKit
import MainThingCore
import SwiftUI
import os

/// The open card's pointer: the one hover tracker for every row, and every press on the card.
///
/// Hover: `HoverController.evaluate` hands in each cursor move; the point maps to a slot
/// (`CardMap`) and lands in `NotchModel.hover`, the only hover state the rows draw. Presses: a
/// local monitor sees mouse down, drag and up in the notch panel and classifies them
/// (`CardPress`): a click crosses a task off or opens the add card. The rows are plain views with
/// no gestures or buttons of their own, so a press anywhere means one thing.
@MainActor
final class CardController {
    private let model: NotchModel
    private let store: TaskStore
    private let panel: NSPanel
    private let toggle: (TaskList.Row) -> Void
    private let log = Logger(subsystem: MainThingBundleID, category: "card")
    private var monitor: Any?
    private var press: CardPress?

    init(model: NotchModel, store: TaskStore, panel: NSPanel, toggle: @escaping (TaskList.Row) -> Void) {
        self.model = model
        self.store = store
        self.panel = panel
        self.toggle = toggle
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    // MARK: Where the pointer is

    /// The card as it is laid out now.
    var map: CardMap {
        let notes = (model.apiBound ? 0 : 1) + store.events.failing.count
        return CardMap(
            notchHeight: model.geometry.notchHeight,
            taskCount: store.list.count,
            notesHeight: CGFloat(notes) * (OpenLayout.noteSpacing + OpenLayout.noteHeight),
            rowsMax: model.rowsMaxHeight,
            scroll: model.rowsScroll
        )
    }

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

    /// Every cursor move the app sees, in panel coordinates; nil when the cursor is off the card
    /// or the card is closed. The one hover tracker.
    func pointer(at panelPoint: CGPoint?) {
        guard let panelPoint, model.isOpen else {
            model.setHover(.none, key: nil, animated: !reduceMotion)
            return
        }
        let slot = map.slot(atY: cardPoint(panelPoint).y)
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
        // Control click is the right click menu.
        guard event.window === panel, model.isOpen, !event.modifierFlags.contains(.control) else { return }
        let p = point(of: event)
        let slot = map.slot(atY: p.y)
        press = CardPress(slot: slot, start: p, onHandle: CardMap.inHandle(x: p.x))
        model.pressed = slot
    }

    private func dragged(_ event: NSEvent) {
        guard var press else { return }
        press.move(to: point(of: event))
        self.press = press
        if press.kind != .pressed, model.pressed != .none { model.pressed = .none }
    }

    private func up(_ event: NSEvent) {
        guard let press else { return }
        self.press = nil
        model.pressed = .none
        if let slot = press.click { click(slot) }
    }

    private func click(_ slot: CardSlot) {
        switch slot {
        case .task(let index):
            guard store.list.rows.indices.contains(index) else { return }
            toggle(store.list.rows[index])
        case .undo, .add, .none:
            break
        }
    }

    // MARK: The list and the card

    /// The card closed: no hover, no press.
    func closed() {
        press = nil
        model.pressed = .none
        model.setHover(.none, key: nil, animated: false)
    }
}
