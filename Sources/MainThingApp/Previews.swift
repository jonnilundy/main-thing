import AppKit
import MainThingCore
import SwiftUI

/// States a preview pins that the views otherwise only reach through the cursor or a running
/// animation. The app never sets it, so every field stays nil there.
struct PreviewPins {
    /// This row's key shows as hovered: the pill fill and, unless struck, the cross off preview.
    var hovered: String?
    /// Crossed off rows draw their ink this far, 0...1, instead of all the way.
    var ink: Double?
    /// The reminder sweep counter; the fraction is the band's progress across the title.
    var sweep: Double?
}

extension EnvironmentValues {
    @Entry var previewPins = PreviewPins()
}

// Every visual state of the notch and the editor as a preview, for `scripts/render-previews.sh`.
// Fixed list, fixed sizes, a dark backdrop, no timers: nothing reads or writes the real tasks
// file, the app's defaults, the network or audio.

private let sampleTitles = [
    "Ship the launch post",
    "Reply to the design review",
    "Update the changelog",
    "Book the offsite room",
    "Draft the Q4 plan",
]

/// A 14 inch MacBook Pro: the notch hangs below a 32pt menu bar under a 185pt housing.
private let previewScreen = ScreenInfo(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
    safeAreaTop: 32,
    auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
    auxiliaryTopRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32)
)

private let backdrop = Color(red: 0.16, green: 0.16, blue: 0.18)

/// The notch over the backdrop. `pending` and `hovered` are row indexes in `titles`.
@MainActor
private func notch(
    open: Bool,
    titles: [String] = sampleTitles,
    pending: [Int] = [],
    hovered: Int? = nil,
    ink: Double? = nil,
    sweep: Double? = nil,
    height: CGFloat
) -> some View {
    let store = TaskStore(previewTitles: titles)
    let geometry = NotchGeometry(screen: previewScreen)
    let model = NotchModel(geometry: geometry, apiPort: APIPort.preferred)
    let rows = store.list.rows
    model.isOpen = open
    model.forceOpen = open
    model.openWidth = PanelLayout.openWidth(rows: rows, geometry: geometry)
    for index in pending { _ = model.pending.toggle(rows[index].key) }
    let pins = PreviewPins(hovered: hovered.map { rows[$0].key }, ink: ink, sweep: sweep)
    return NotchView(store: store, model: model)
        .environment(\.previewPins, pins)
        // The snapshot is taken at once: states set on appear land without their animation.
        .transaction { $0.animation = nil }
        .frame(width: 520, height: height)
        .background(backdrop)
}

/// The list editor over the backdrop.
@MainActor
private func editor(titles: [String], conflict: Bool = false) -> some View {
    let model = EditorModel(draft: EditorDraft(titles.map { TaskItem($0) }))
    model.conflict = conflict
    let notch = NotchModel(geometry: NotchGeometry(screen: previewScreen), apiPort: APIPort.preferred)
    return EditorView(editor: model, notch: notch, controller: PreviewEditorActions())
        .background(FocusSink())
        .frame(width: model.size.width, height: model.size.height)
        .padding(24)
        .background(backdrop)
}

/// Takes the preview window's first responder, so no field is focused with its title selected.
private struct FocusSink: NSViewRepresentable {
    final class Sink: NSView {
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.initialFirstResponder = self
            window?.makeFirstResponder(self)
        }
    }

    func makeNSView(context: Context) -> Sink { Sink() }
    func updateNSView(_ view: Sink, context: Context) {}
}

/// The editor's buttons and fields do nothing in a preview.
private struct PreviewEditorActions: EditorActions {
    func rename(_ id: UUID, _ title: String) {}
    func remove(_ id: UUID) {}
    func dragRow(_ id: UUID, translation: CGFloat) {}
    func endDragRow() {}
    func moveWindow() {}
    func endMoveWindow() {}
    func caretToEnd() {}
    func reload() {}
    func overwrite() {}
    func cancel() {}
    func save() {}
}

#Preview("Collapsed", traits: .sizeThatFitsLayout) {
    notch(open: false, height: 64)
}

#Preview("Collapsed empty", traits: .sizeThatFitsLayout) {
    notch(open: false, titles: [], height: 64)
}

#Preview("Open", traits: .sizeThatFitsLayout) {
    notch(open: true, height: 180)
}

#Preview("Open hovered row", traits: .sizeThatFitsLayout) {
    notch(open: true, hovered: 2, height: 180)
}

#Preview("Open mid cross off", traits: .sizeThatFitsLayout) {
    // The pen eases out: this far into the stroke the ink is 60 percent across the title.
    notch(open: true, pending: [2], hovered: 2, ink: 1 - cbrt(0.4), height: 180)
}

#Preview("Reminder shimmer", traits: .sizeThatFitsLayout) {
    notch(open: false, sweep: 0.5, height: 64)
}

#Preview("Editor", traits: .sizeThatFitsLayout) {
    editor(titles: Array(sampleTitles.prefix(4)))
}

#Preview("Editor conflict", traits: .sizeThatFitsLayout) {
    editor(titles: Array(sampleTitles.prefix(4)), conflict: true)
}
