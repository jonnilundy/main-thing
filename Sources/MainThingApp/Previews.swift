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
    /// The Undo row shows as hovered.
    var undo = false
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

/// A 14 inch MacBook Pro: the card hangs below a 32pt menu bar, bridged to a 185pt housing.
private let previewScreen = ScreenInfo(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
    safeAreaTop: 32,
    auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
    auxiliaryTopRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32)
)

/// A Studio Display: no hardware notch, the shape sits in the 30pt menu bar row.
private let plainScreen = ScreenInfo(
    frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
    visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410)
)

private let backdrop = Color(red: 0.16, green: 0.16, blue: 0.18)
/// A light menu bar, so a gap between the camera notch and the card would show as a grey strip.
private let menuBar = Color(white: 0.8)

/// The desktop behind the notch. Under a hardware notch: the menu bar row with the camera housing
/// in it, drawn under the app's shape, as the screen shows it.
private struct Backdrop: View {
    let geometry: NotchGeometry

    var body: some View {
        ZStack(alignment: .top) {
            backdrop
            if let bridge = geometry.bridgeRect {
                menuBar.frame(height: bridge.height)
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                    .fill(.black)
                    .frame(width: bridge.width, height: bridge.height)
                    .offset(x: geometry.bridgeOffset)
            }
        }
    }
}

/// The notch over the backdrop. `pending` and `hovered` are row indexes in `titles`.
@MainActor
private func notch(
    open: Bool,
    screen: ScreenInfo = previewScreen,
    titles: [String] = sampleTitles,
    pending: [Int] = [],
    hovered: Int? = nil,
    ink: Double? = nil,
    sweep: Double? = nil,
    height: CGFloat,
    edit: (NotchModel, TaskStore) -> Void = { _, _ in }
) -> some View {
    let store = TaskStore(previewTitles: titles)
    let geometry = NotchGeometry(screen: screen)
    let model = NotchModel(geometry: geometry, apiPort: APIPort.preferred)
    let rows = store.list.rows
    model.isOpen = open
    model.forceOpen = open
    model.openWidth = PanelLayout.openWidth(rows: rows, geometry: geometry)
    for index in pending { _ = model.pending.toggle(rows[index].key) }
    let pins = PreviewPins(hovered: hovered.map { rows[$0].key }, ink: ink, sweep: sweep)
    edit(model, store)
    return NotchView(store: store, model: model)
        .environment(\.previewPins, pins)
        // The snapshot is taken at once: states set on appear land without their animation.
        .transaction { $0.animation = nil }
        // `height` is the card's room; the menu bar row comes on top under a hardware notch.
        .frame(width: 520, height: height + geometry.cardTop)
        .background(Backdrop(geometry: geometry))
}

#Preview("Collapsed", traits: .sizeThatFitsLayout) {
    notch(open: false, height: 64)
}

#Preview("Collapsed empty", traits: .sizeThatFitsLayout) {
    // Under a hardware notch: nothing of ours, the camera notch alone.
    notch(open: false, titles: [], height: 64)
}

#Preview("Collapsed long title", traits: .sizeThatFitsLayout) {
    // Wider than the camera notch: the join flares out to the card's width.
    notch(open: false, titles: ["Write the launch post for the new API and send it to the team"] + sampleTitles.dropFirst(), height: 64)
}

#Preview("Open", traits: .sizeThatFitsLayout) {
    notch(open: true, height: 210)
}

#Preview("Open empty", traits: .sizeThatFitsLayout) {
    // Opened from the camera with nothing on the list: the card grows out of the notch.
    notch(open: true, titles: [], height: 120)
}

#Preview("No notch collapsed", traits: .sizeThatFitsLayout) {
    notch(open: false, screen: plainScreen, height: 64)
}

#Preview("No notch open", traits: .sizeThatFitsLayout) {
    notch(open: true, screen: plainScreen, height: 210)
}

#Preview("Open hovered row", traits: .sizeThatFitsLayout) {
    notch(open: true, hovered: 2, height: 210)
}

#Preview("Open mid cross off", traits: .sizeThatFitsLayout) {
    // The pen eases out: this far into the stroke the ink is 60 percent across the title.
    notch(open: true, pending: [2], hovered: 2, ink: 1 - cbrt(0.4), height: 210)
}

#Preview("Reminder shimmer", traits: .sizeThatFitsLayout) {
    notch(open: false, sweep: 0.5, height: 64)
}

#Preview("Drag in progress", traits: .sizeThatFitsLayout) {
    // Row 4 held by its number, dragged up past row 3 and nearly to row 2: rows 2 and 3 have
    // moved down to make room.
    notch(open: true, height: 210) { model, store in
        let map = CardMap(model: model, store: store)
        let key = store.list.rows[3].key
        model.drag = CardDrag(key: key, from: 3, target: 1, offset: map.center(ofTask: 1) - map.center(ofTask: 3) + 6)
    }
}

#Preview("Add card hover", traits: .sizeThatFitsLayout) {
    notch(open: true, height: 210) { model, _ in model.hover = .add }
}

#Preview("Add field open", traits: .sizeThatFitsLayout) {
    notch(open: true, height: 210) { model, _ in
        model.adding = true
        model.addText = "Book the flights"
    }
}

#Preview("Long press menu", traits: .sizeThatFitsLayout) {
    notch(open: true, height: 210) { model, store in
        let map = CardMap(model: model, store: store)
        model.hover = .task(2)
        model.menu = CardMenu(
            key: store.list.rows[2].key,
            frame: RowMenu.frame(rowCenterY: map.centerY(of: .task(2)), cardWidth: model.openWidth),
            hovered: .rename
        )
    }
}

#Preview("Rename field", traits: .sizeThatFitsLayout) {
    notch(open: true, height: 210) { model, store in
        model.renaming = store.list.rows[1].key
        model.renameText = "Reply to the design review today"
    }
}

#Preview("Discard undo", traits: .sizeThatFitsLayout) {
    // Task 3 discarded a moment ago: its Undo shows where it was, the pointer on it.
    notch(open: true, titles: sampleTitles.enumerated().filter { $0.offset != 2 }.map(\.element), height: 210) { model, _ in
        model.discarded = Discarded(task: TaskItem(sampleTitles[2]), index: 2, at: 0)
        model.hover = .undo
    }
}

// The Settings tabs. Secrets in memory and defaults only registered, never written: a render
// touches no Keychain item and no defaults file.

@MainActor
private func adaptersPreviewModel() -> AdaptersModel {
    let defaults = UserDefaults(suiteName: "com.jonnilundy.mainthing.preview") ?? .standard
    defaults.register(defaults: [
        AdapterKeys.enabled("linear"): true,
        AdapterKeys.enabled("openbrain"): true,
        AdapterKeys.value("openbrain", "OPEN_BRAIN_API_URL"): "https://example-deployment.convex.site",
    ])
    let bundleID = "com.jonnilundy.mainthing.preview"
    let secrets = MemorySecretStore([AdapterKeys.keychainService(bundleID: bundleID, adapter: "openbrain") + "/OPEN_BRAIN_API_KEY": "obr_preview"])
    let settings = AdapterSettings(
        defaults: defaults, secrets: secrets, bundleID: bundleID,
        bundledDirectory: URL(fileURLWithPath: "/var/empty"), configDirectory: URL(fileURLWithPath: "/var/empty")
    )
    let model = AdaptersModel(settings: settings, store: nil)
    model.previewRuns = [
        "linear": RunRecord(at: Date().addingTimeInterval(-300), exit: 1, ms: 412, stderr: "linear: Linear API: Authentication required (HTTP 400)"),
        "openbrain": RunRecord(at: Date().addingTimeInterval(-20), exit: 0, ms: 230),
    ]
    model.pin(.failed("Linear API: Authentication required (HTTP 400)"), for: BuiltInAdapters.linear)
    model.pin(.ok("Connected to example-deployment.convex.site"), for: BuiltInAdapters.openBrain)
    return model
}

#Preview("Settings General", traits: .sizeThatFitsLayout) {
    GeneralSettings(sounds: nil)
}

#Preview("Settings Shortcuts", traits: .sizeThatFitsLayout) {
    ShortcutsSettings()
}

#Preview("Settings Adapters", traits: .sizeThatFitsLayout) {
    AdaptersSettings(model: adaptersPreviewModel())
}

#Preview("Settings Updates", traits: .sizeThatFitsLayout) {
    UpdatesSettings(updater: nil)
}
