import AppKit
import MainThingCore
import SwiftUI
import os

/// Tear off: a press anywhere on the open card, then a drag down. Under 6pt it stays a click.
/// Past that the card stretches (rubber band, `TearOff`); at 24pt past its edge the editor window
/// appears under the cursor with the same grab offset, follows it 1:1 until mouse up and stays.
/// The notch collapses. Reduce Motion: no stretch, the window appears at the release.
///
/// A local monitor sees the presses, so rows inside a scroll view count too; the SwiftUI buttons
/// still get their events, and `NotchModel.dragMoved` keeps a drag's mouse up from crossing off.
@MainActor
final class TearOffController {
    private let model: NotchModel
    private let panel: NSPanel
    private let hover: HoverController
    private let editor: EditorController
    private let log = Logger(subsystem: MainThingBundleID, category: "tearoff")
    private var monitor: Any?
    private var drag: TearOffDrag?
    /// The cursor's offset from the card's top left at the press, y growing down.
    private var grab: CGPoint = .zero
    /// The editor's size, known at the press, for clamping the grab.
    private var editorSize: CGSize = .zero

    init(model: NotchModel, panel: NSPanel, hover: HoverController, editor: EditorController) {
        self.model = model
        self.panel = panel
        self.hover = hover
        self.editor = editor
    }

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let screen = HoverController.screenPoint(of: event)
                switch event.type {
                case .leftMouseDown: self.down(at: screen, window: event.window)
                case .leftMouseDragged: self.dragged(to: screen)
                case .leftMouseUp: self.up(at: screen)
                default: break
                }
            }
            return event
        }
    }

    private func panelPoint(_ screen: CGPoint) -> CGPoint {
        NotchHover.panelPoint(screenPoint: screen, panelFrame: panel.frame)
    }

    private func down(at screen: CGPoint, window: NSWindow?) {
        drag = nil
        model.dragMoved = false
        guard window === panel, model.isOpen, !model.editorOpen, !model.forceOpen else { return }
        let point = panelPoint(screen)
        let card = model.shapeRect
        guard card.contains(point) else { return }
        grab = CGPoint(x: point.x - (card.minX + NotchGeometry.flare), y: point.y - card.minY)
        editorSize = editor.tornSize()
        drag = TearOffDrag(start: point, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func dragged(to screen: CGPoint) {
        guard var drag else { return }
        let before = drag.phase
        drag.move(to: panelPoint(screen))
        self.drag = drag
        switch drag.phase {
        case .press:
            return
        case .stretch:
            if before == .press {
                model.dragMoved = true
                model.tearing = true
                log.notice("tear off drag started")
            }
            let stretch = drag.stretch
            withTransaction(Transaction(animation: nil)) { model.tearStretch = stretch }
        case .torn:
            if before != .torn {
                model.dragMoved = true
                model.tearing = true
                withTransaction(Transaction(animation: nil)) { model.tearStretch = 0 }
                editor.openTorn(topLeft: topLeft(for: screen))
                log.notice("torn off at \(Int(drag.travel), privacy: .public)pt of travel")
            } else {
                editor.track(topLeft: topLeft(for: screen))
            }
        }
    }

    private func up(at screen: CGPoint) {
        guard let drag else { return }
        self.drag = nil
        let release = drag.release()
        model.tearing = false
        switch release {
        case .click:
            break
        case .springBack:
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : Motion.openSpring) {
                model.tearStretch = 0
            }
        case .drop:
            editor.dropTorn()
        case .appear:
            editor.openTorn(topLeft: topLeft(for: screen))
            editor.dropTorn()
        }
        if release != .click { log.notice("tear off release: \(String(describing: release), privacy: .public)") }
        hover.refresh()
    }

    /// The editor's top left (AppKit screen coordinates) that keeps the grab offset under the cursor.
    private func topLeft(for screen: CGPoint) -> CGPoint {
        let offset = TearOff.grab(grab, in: editorSize)
        return CGPoint(x: (screen.x - offset.x).rounded(), y: (screen.y + offset.y).rounded())
    }
}
