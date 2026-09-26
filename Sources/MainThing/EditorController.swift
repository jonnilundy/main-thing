import AppKit
import MainThingCore
import Observation
import SwiftUI
import os

/// The editor's UI state. The draft itself is pure (`EditorDraft`); this adds focus, the conflict
/// prompt and the row being dragged.
@Observable
@MainActor
final class EditorModel {
    var draft: EditorDraft
    /// The row whose field has focus, as the view reports it.
    var focused: UUID?
    /// A focus change the controller asks for; the view applies it when `focusTick` moves.
    var focusRequest: UUID?
    var focusTick = 0
    /// Save found the live list changed since open: Reload or Overwrite.
    var conflict = false
    /// While the window flies in or out of the notch the content keeps its size and scales
    /// with the window instead of laying out again.
    var morphing = false
    /// The row being reordered, where it started, and its offset from the slot it sits in now.
    var dragID: UUID?
    var dragStart = 0
    var dragOffset: CGFloat = 0

    init(draft: EditorDraft) {
        self.draft = draft
    }

    var size: CGSize {
        CGSize(width: EditorLayout.width, height: EditorLayout.height(rows: draft.rows.count, conflict: conflict))
    }

    func focus(_ id: UUID?) {
        focusRequest = id
        focusTick += 1
    }
}

/// Opens, runs and closes the list editor window. Save replaces the list with source `editor`:
/// a replace, so removed tasks are deleted and no adapter or `task-completed` runs. After Save or
/// Cancel the window shrinks into the notch and closes. While it is open the notch stays collapsed.
@MainActor
final class EditorController {
    static let leftKey = "editorLeft"
    static let topKey = "editorTop"
    /// The flight into and out of the notch.
    static let morphDuration: TimeInterval = 0.24

    private let store: TaskStore
    private let model: NotchModel
    private let notchPanel: NSPanel
    private let hover: HoverController
    private let log = Logger(subsystem: MainThingBundleID, category: "editor")
    private var panel: EditorPanel?
    private var editor: EditorModel?
    private var keyMonitor: Any?
    private var closing = false
    /// Window move by the card background: where the drag started.
    private var moveStart: (origin: CGPoint, mouse: CGPoint)?

    init(store: TaskStore, model: NotchModel, notchPanel: NSPanel, hover: HoverController) {
        self.store = store
        self.model = model
        self.notchPanel = notchPanel
        self.hover = hover
    }

    var isOpen: Bool { panel != nil }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Opening

    /// "Edit List" from the right click menu: at the last saved spot, flying out of the notch.
    func openFromMenu() {
        if let panel, !closing {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard !closing else { return }
        let editor = makeEditor()
        let frame = clampToScreen(NSRect(origin: .zero, size: editor.size).withTopLeft(savedTopLeft()))
        let panel = present(editor, frame: frame)
        // Placed and transparent before it is ordered in, so the full frame never flashes first.
        if reduceMotion {
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 1
            }
        } else {
            morph(panel, editor, from: notchRect(), to: frame, alphaFrom: 0, alphaTo: 1) {}
            panel.makeKeyAndOrderFront(nil)
        }
        editor.focus(editor.draft.rows.first?.id)
        log.notice("opened from the menu at \(NSStringFromRect(frame), privacy: .public)")
    }

    /// The window's size for the list as it is now, before a tear off builds it.
    func tornSize() -> CGSize {
        CGSize(width: EditorLayout.width, height: EditorLayout.height(rows: max(store.list.count, 1)))
    }

    /// Builds the window for a tear off, top left at `topLeft` (AppKit screen coordinates), shown
    /// but not key while the mouse is still down. Returns the window size.
    @discardableResult
    func openTorn(topLeft: CGPoint) -> CGSize {
        guard panel == nil, !closing else { return panel?.frame.size ?? .zero }
        let editor = makeEditor()
        let frame = NSRect(origin: .zero, size: editor.size).withTopLeft(topLeft)
        let panel = present(editor, frame: frame)
        panel.orderFrontRegardless()
        log.notice("torn off at \(NSStringFromRect(frame), privacy: .public)")
        return editor.size
    }

    /// Follows the cursor 1:1 while the tear off is still held.
    func track(topLeft: CGPoint) {
        guard let panel, !closing else { return }
        panel.setFrameTopLeftPoint(topLeft)
    }

    /// Mouse up after a tear off: the window stays where it is and takes typing.
    func dropTorn() {
        guard let panel, let editor, !closing else { return }
        let frame = clampToScreen(panel.frame)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
        panel.makeKeyAndOrderFront(nil)
        editor.focus(editor.draft.rows.first?.id)
        saveTopLeft()
        log.notice("dropped at \(NSStringFromRect(frame), privacy: .public)")
    }

    private func makeEditor() -> EditorModel {
        var draft = EditorDraft(store.list.tasks)
        if draft.rows.isEmpty { draft.insert(after: nil) }
        return EditorModel(draft: draft)
    }

    private func present(_ editor: EditorModel, frame: NSRect) -> EditorPanel {
        model.editorOpen = true
        hover.editorOpened()
        let panel = EditorPanel(contentRect: frame)
        let root = EditorView(editor: editor, notch: model, controller: self)
        panel.contentView = EditorHostingView(rootView: root)
        panel.setFrame(frame, display: false)
        self.panel = panel
        self.editor = editor
        installKeys()
        return panel
    }

    // MARK: Editing, called by the view

    func rename(_ id: UUID, _ title: String) {
        editor?.draft.rename(id: id, title: title)
    }

    func insert(after id: UUID?) {
        guard let editor else { return }
        let new = editor.draft.insert(after: id ?? editor.draft.rows.last?.id)
        fit()
        editor.focus(new)
    }

    func remove(_ id: UUID) {
        guard let editor else { return }
        var next = editor.draft.remove(id: id)
        if editor.draft.rows.isEmpty { next = editor.draft.insert(after: nil) }
        fit()
        editor.focus(next)
    }

    /// Reorder by the handle: the row follows the cursor and takes the slot it is over.
    func dragRow(_ id: UUID, translation: CGFloat) {
        guard let editor else { return }
        if editor.dragID != id {
            editor.dragID = id
            editor.dragStart = editor.draft.index(of: id) ?? 0
        }
        guard let current = editor.draft.index(of: id) else { return }
        let steps = Int((translation / EditorLayout.rowHeight).rounded())
        let target = min(max(editor.dragStart + steps, 0), editor.draft.rows.count - 1)
        if target != current {
            withAnimation(reduceMotion ? nil : Motion.openSpring) {
                editor.draft.move(from: current, to: target)
            }
        }
        editor.dragOffset = translation - CGFloat(target - editor.dragStart) * EditorLayout.rowHeight
    }

    /// The focused field keeps its text: caret at the end, nothing selected.
    func caretToEnd() {
        guard let field = panel?.firstResponder as? NSTextView else { return }
        field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
    }

    func endDragRow() {
        guard let editor else { return }
        withAnimation(reduceMotion ? nil : Motion.openSpring) { editor.dragOffset = 0 }
        editor.dragID = nil
    }

    /// The card background moves the window. Positions come from the cursor itself, so moving
    /// the window under the gesture does not feed back into it.
    func moveWindow() {
        guard let panel, !closing else { return }
        let mouse = NSEvent.mouseLocation
        if moveStart == nil { moveStart = (panel.frame.origin, mouse) }
        guard let start = moveStart else { return }
        panel.setFrameOrigin(CGPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    func endMoveWindow() {
        moveStart = nil
        guard let panel else { return }
        let frame = clampToScreen(panel.frame)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
        saveTopLeft()
    }

    // MARK: Save and Cancel

    func save() {
        guard let editor, !closing else { return }
        if editor.draft.conflict(current: store.list.tasks) {
            log.notice("save: the list changed while editing, asking")
            editor.conflict = true
            fit()
            return
        }
        close(saving: editor.draft.result())
    }

    func cancel() {
        guard !closing else { return }
        close(saving: nil)
    }

    /// Conflict: drop the edits and start again from the live list.
    func reload() {
        guard let editor, !closing else { return }
        var draft = EditorDraft(store.list.tasks)
        if draft.rows.isEmpty { draft.insert(after: nil) }
        editor.draft = draft
        editor.conflict = false
        fit()
        editor.focus(draft.rows.first?.id)
        log.notice("reloaded the live list")
    }

    /// Conflict: save the edits over the live list.
    func overwrite() {
        guard let editor, !closing else { return }
        close(saving: editor.draft.result())
    }

    private func close(saving tasks: [TaskItem]?) {
        guard let panel, let editor else { return }
        closing = true
        if let tasks {
            if tasks != store.list.tasks {
                store.replace(tasks, source: EventSource.editor)
                log.notice("saved \(tasks.count, privacy: .public) tasks")
            } else {
                log.notice("save: nothing changed")
            }
        } else {
            log.notice("cancelled")
        }
        saveTopLeft()
        removeKeys()
        let finish: @MainActor () -> Void = { [weak self] in
            panel.orderOut(nil)
            guard let self else { return }
            self.panel = nil
            self.editor = nil
            self.closing = false
            self.model.editorOpen = false
            self.hover.refresh()
        }
        if reduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { finish() } })
        } else {
            morph(panel, editor, from: panel.frame, to: notchRect(), alphaFrom: 1, alphaTo: 0, completion: finish)
        }
    }

    // MARK: Geometry

    /// The collapsed notch in AppKit screen coordinates.
    private func notchRect() -> NSRect {
        let shape = model.shapeRect.isEmpty
            ? model.geometry.collapsedShapeFrame(contentWidth: model.geometry.minimumWidth)
            : model.shapeRect
        let panelFrame = notchPanel.frame
        return NSRect(x: panelFrame.minX + shape.minX, y: panelFrame.maxY - shape.maxY, width: shape.width, height: shape.height)
    }

    /// The window flies between two frames and fades, with its content scaled, not laid out again.
    private func morph(_ panel: EditorPanel, _ editor: EditorModel, from: NSRect, to: NSRect, alphaFrom: CGFloat, alphaTo: CGFloat, completion: @escaping @MainActor () -> Void) {
        editor.morphing = true
        panel.alphaValue = alphaFrom
        panel.setFrame(from, display: true)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = EditorController.morphDuration
            // Ease out, fast then settling: no ease in anywhere.
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel.animator().setFrame(to, display: true)
            panel.animator().alphaValue = alphaTo
        }, completionHandler: {
            MainActor.assumeIsolated {
                editor.morphing = false
                completion()
            }
        })
    }

    /// Keeps the top left corner and takes the height the rows and the footer need.
    private func fit() {
        guard let panel, let editor, !closing else { return }
        let frame = clampToScreen(NSRect(origin: .zero, size: editor.size).withTopLeft(panel.frame.topLeft))
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    private func clampToScreen(_ frame: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return frame }
        return EditorLayout.clamp(frame, into: visible)
    }

    /// The last spot the window was left at, else centered under the notch.
    private func savedTopLeft() -> CGPoint {
        let defaults = UserDefaults.standard
        if let left = defaults.object(forKey: EditorController.leftKey) as? Double,
           let top = defaults.object(forKey: EditorController.topKey) as? Double {
            return CGPoint(x: left, y: top)
        }
        let geometry = model.geometry
        let x = EditorLayout.defaultTopLeft(centerX: geometry.centerX, notchBottom: 0).x
        return CGPoint(x: x, y: geometry.panelFrame.maxY - geometry.notchHeight - EditorLayout.gapBelowNotch)
    }

    private func saveTopLeft() {
        guard let panel else { return }
        let topLeft = panel.frame.topLeft
        UserDefaults.standard.set(Double(topLeft.x), forKey: EditorController.leftKey)
        UserDefaults.standard.set(Double(topLeft.y), forKey: EditorController.topKey)
    }

    // MARK: Keys

    /// Cmd S saves, Esc cancels, Return adds a row below, Delete on an empty row removes it.
    private func installKeys() {
        removeKeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let used = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel, event.window === panel else { return false }
                return self.handle(event, in: panel)
            }
            return used ? nil : event
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// True when the key was used.
    private func handle(_ event: NSEvent, in panel: NSWindow) -> Bool {
        guard let editor, !closing else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Typing with an input method: Return and Delete belong to the composition.
        let composing = (panel.firstResponder as? NSTextView)?.hasMarkedText() ?? false
        // Cmd S by the character, so it is S on any keyboard layout.
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "s" {
            save()
            return true
        }
        switch event.keyCode {
        case 53: // Esc
            cancel()
            return true
        case 36, 76: // Return, Enter
            guard modifiers.isEmpty, !composing, !editor.conflict else { return false }
            insert(after: editor.focused)
            return true
        case 51, 117: // Delete, Forward Delete
            guard modifiers.isEmpty, !composing, let id = editor.focused, let i = editor.draft.index(of: id),
                  editor.draft.rows[i].title.isEmpty, editor.draft.rows.count > 1 else { return false }
            remove(id)
            return true
        default:
            return false
        }
    }
}

extension NSRect {
    /// AppKit's top left corner: minX, maxY.
    var topLeft: CGPoint { CGPoint(x: minX, y: maxY) }

    func withTopLeft(_ point: CGPoint) -> NSRect {
        NSRect(x: point.x, y: point.y - height, width: width, height: height)
    }
}
