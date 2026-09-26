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
    /// The add card shows as hovered.
    var add = false
}

extension EnvironmentValues {
    @Entry var previewPins = PreviewPins()
}

// Every visual state of the notch as a preview, for `scripts/render-previews.sh`.
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
