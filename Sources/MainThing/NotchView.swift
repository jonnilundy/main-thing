import AppKit
import MainThingCore
import SwiftUI
import os

/// The notch. Collapsed: a black shape at the top center with the current task inside.
/// Open: every task flush left, the current one large; hover previews a cross off, a click draws it.
struct NotchView: View {
    let store: TaskStore
    let model: NotchModel
    var onToggle: (TaskList.Row) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            NotchBody(store: store, model: model, onToggle: onToggle)
                // The hosting view fills the panel, so the global space is panel space, origin top left.
                // A GeometryReader preference in the background never delivered the laid out frame here
                // (it fired once with zero), so the shape rect goes through onGeometryChange instead.
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { rect in
                    viewLog.debug("shape rect \(NSStringFromRect(rect), privacy: .public)")
                    model.shapeRect = rect
                }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private let viewLog = Logger(subsystem: MainThingBundleID, category: "hover")
private let renderLog = Logger(subsystem: MainThingBundleID, category: "render")

struct NotchBody: View {
    let store: TaskStore
    let model: NotchModel
    let onToggle: (TaskList.Row) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rows = store.list.rows
        let keys = rows.map(\.key)
        let title = rows.first?.title
        let geometry = model.geometry
        let collapsedWidth = NotchMetrics.width(for: title, minimum: geometry.minimumWidth)
        let openWidth = max(collapsedWidth, model.openWidth)
        // The shape width springs between these. Content is laid out at its own final width,
        // never at the animating width, and the clip hides the overflow while the spring settles.
        let width = model.isOpen ? openWidth : collapsedWidth
        let shape = NotchShape(
            topRadius: NotchMetrics.flare,
            bottomRadius: model.isOpen ? NotchMetrics.openBottomRadius : NotchMetrics.bottomRadius
        )
        VStack(spacing: 0) {
            // The notch row, hanging under the menu bar. Holds the title when collapsed.
            ZStack {
                if !model.isOpen {
                    CollapsedTitle(rows: rows, height: geometry.notchHeight, minimumWidth: geometry.minimumWidth)
                        .transition(Motion.collapsedTitle(reduceMotion))
                }
            }
            .frame(width: width, height: geometry.notchHeight)
            if model.isOpen {
                OpenContent(store: store, model: model, onToggle: onToggle, width: openWidth)
                    .transition(Motion.openContent(reduceMotion))
            }
        }
        .padding(.horizontal, NotchMetrics.flare)
        // Pure black, no translucency: it must match a hardware notch.
        .background(shape.fill(.black))
        .clipShape(shape)
        .contentShape(shape)
        .animation(Motion.shape(reduceMotion, opening: model.isOpen), value: model.isOpen)
        .animation(Motion.size(reduceMotion, open: model.isOpen), value: keys)
        .animation(Motion.size(reduceMotion, open: model.isOpen), value: model.openWidth)
        .contextMenu { NotchMenu(store: store) }
    }
}

/// The title in the collapsed notch. Each title has its own fixed width, so a title that
/// fits never truncates while the shape width animates around it.
struct CollapsedTitle: View {
    let rows: [TaskList.Row]
    let height: CGFloat
    let minimumWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let current = rows.first {
                Text(current.title)
                    .font(NotchMetrics.font)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, NotchMetrics.textInset)
                    .frame(width: NotchMetrics.width(for: current.title, minimum: minimumWidth), height: height)
                    .id(current.key)
                    .transition(Motion.push(reduceMotion))
            }
        }
        .animation(Motion.content(reduceMotion), value: rows.map(\.key))
    }
}

/// The open card: every row, the current one large. Past 60 percent of the screen the rows scroll.
struct OpenContent: View {
    let store: TaskStore
    let model: NotchModel
    let onToggle: (TaskList.Row) -> Void
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rows = store.list.rows
        let keys = rows.map(\.key)
        VStack(alignment: .leading, spacing: OpenLayout.rowSpacing) {
            if rows.isEmpty {
                Text("No tasks")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .transition(.opacity)
            } else {
                RowsBlock(maxHeight: model.rowsMaxHeight) {
                    VStack(alignment: .leading, spacing: OpenLayout.rowSpacing) {
                        ForEach(rows) { row in
                            TaskRow(
                                row: row,
                                isCurrent: row.key == keys.first,
                                struck: model.pending.isPending(row.key),
                                width: width,
                                action: { onToggle(row) }
                            )
                            .transition(Motion.push(reduceMotion))
                        }
                    }
                    .animation(Motion.content(reduceMotion), value: keys)
                }
            }
            if !model.apiBound {
                Text("API off on port " + String(model.apiPort))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            // A hook or adapter whose last run failed, until it next succeeds.
            ForEach(store.events.failing, id: \.self) { label in
                Text("sync failed: " + label)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, OpenLayout.horizontalPadding)
        .padding(.top, OpenLayout.topPadding)
        .padding(.bottom, OpenLayout.bottomPadding)
        // Laid out at the final open width. The width itself does not animate here.
        .frame(width: width, alignment: .leading)
        .animation(nil, value: width)
        .animation(Motion.content(reduceMotion), value: keys)
    }
}

/// The rows, plain when they fit, in a scroll view when they do not. The clipped edge gets a
/// short fade instead of a hard cut: at the bottom while more rows are below, at the top once scrolled.
struct RowsBlock<Content: View>: View {
    private let fadeHeight: CGFloat = 18
    let maxHeight: CGFloat?
    @ViewBuilder let content: Content
    @State private var topClipped = false
    @State private var bottomClipped = false

    var body: some View {
        if let maxHeight {
            ScrollView(.vertical) {
                content
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("rows"))
                    } action: { frame in
                        topClipped = frame.minY < -1
                        bottomClipped = frame.maxY > maxHeight + 1
                    }
            }
            .coordinateSpace(name: "rows")
            .scrollIndicators(.automatic)
            .frame(maxHeight: maxHeight)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: topClipped ? fadeHeight : 0)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: bottomClipped ? fadeHeight : 0)
                }
            }
            .animation(Motion.edgeFade, value: topClipped)
            .animation(Motion.edgeFade, value: bottomClipped)
        } else {
            content
        }
    }
}

/// Press feedback on mouse down: the row dims a touch, the pen touching the paper. The action
/// fires on mouse up only while the cursor is still on the row; dragging away cancels, as a Button does.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// One task, flush left, one line: a title wider than the card truncates with an ellipsis and
/// shows in full as a tooltip. The whole row is the button. Hover shows a faint preview of the
/// cross off; a click draws it like a pen on paper, and 400ms later the row leaves. A click in
/// that window erases the ink and keeps the row.
struct TaskRow: View {
    let row: TaskList.Row
    let isCurrent: Bool
    let struck: Bool
    /// Card content width, for the line count the pen has to cross.
    let width: CGFloat
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let font = isCurrent ? NotchMetrics.titleFont : NotchMetrics.rowFont
        let nsFont = isCurrent ? NotchMetrics.titleNSFont : NotchMetrics.rowNSFont
        let dim = OpenLayout.dimOpacity(increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        let truncated = PanelLayout.width(of: row.title, font: nsFont) > OpenLayout.titleWidth(contentWidth: width)
        Button(action: action) {
            Text(row.title)
                .font(font)
                .foregroundStyle(.white.opacity(isCurrent ? 1 : dim))
                .lineLimit(1)
                .truncationMode(.tail)
                .modifier(Ink(
                    progress: struck ? 1 : 0,
                    preview: hovering && !struck ? 1 : 0,
                    key: row.key,
                    xHeight: nsFont.xHeight,
                    thickness: isCurrent ? 3.2 : 2.8,
                    inkOpacity: isCurrent ? 1 : dim
                ))
                // The pen: linear over 220ms with the ease inside the renderer, so the ink grows from
                // the left end to the right. Undo: a fast erase. Reduce Motion: the ink is just there.
                .animation(reduceMotion ? nil : (struck ? .linear(duration: PenStroke.secondsPerLine) : Motion.unstrike), value: struck)
                .animation(reduceMotion ? nil : Motion.preview, value: hovering)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .onHover { hovering = $0 }
        .help(truncated ? row.title : "")
        .accessibilityLabel(row.title)
        .accessibilityHint(struck ? "Crossed off, leaving. Click again to keep it" : "Click to cross off")
        .accessibilityAction(named: "Cross off") { action() }
    }
}

/// The animatable half: SwiftUI interpolates a modifier's `animatableData`, so the progress and
/// the preview live here and the renderer below only draws.
struct Ink: ViewModifier, @preconcurrency Animatable {
    var progress: Double
    var preview: Double
    var key: String
    var xHeight: CGFloat
    var thickness: CGFloat
    var inkOpacity: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(progress, preview) }
        set {
            progress = newValue.first
            preview = newValue.second
        }
    }

    func body(content: Content) -> some View {
        content.textRenderer(CrossOffRenderer(
            progress: progress, preview: preview, key: key, xHeight: xHeight, thickness: thickness, inkOpacity: inkOpacity
        ))
    }
}

/// Draws the title and the ink over it. `progress` runs 0...lineCount: line 0 is crossed while it
/// goes 0 to 1, line 1 while it goes 1 to 2 (titles are one line now, the loop stays general).
/// `preview` fades a thin line in on hover.
struct CrossOffRenderer: TextRenderer {
    var progress: Double
    var preview: Double
    var key: String
    var xHeight: CGFloat
    var thickness: CGFloat
    var inkOpacity: Double

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let lines = Array(layout)
        renderLog.debug("ink draw \(key, privacy: .public)")
        for (index, line) in lines.enumerated() {
            let bounds = line.typographicBounds
            let t = PenStroke.lineProgress(progress, line: index)
            // The glyphs, dimming to 45 percent as the ink passes.
            var glyphs = context
            glyphs.opacity = 1 - 0.55 * t
            glyphs.draw(line)

            // The strike line sits on the middle of the x-height of this line.
            let y = bounds.rect.minY + bounds.ascent - xHeight / 2
            let from = CGPoint(x: bounds.rect.minX, y: y)
            let to = CGPoint(x: bounds.rect.maxX, y: y)

            if preview > 0, t == 0 {
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                context.stroke(path, with: .color(.white.opacity(0.25 * preview * inkOpacity)), lineWidth: 1)
            }
            if t > 0 {
                let samples = PenStroke.centerline(
                    from: from, to: to, line: index,
                    seed: PenStroke.seed(key: key, line: index), thickness: thickness
                )
                let outline = PenStroke.outline(samples, progress: t)
                if outline.count >= 3 {
                    var path = Path()
                    path.move(to: outline[0])
                    for point in outline.dropFirst() { path.addLine(to: point) }
                    path.closeSubpath()
                    context.fill(path, with: .color(.white.opacity(inkOpacity)))
                }
            }
        }
    }
}

/// Right click menu: Launch at Login, Sounds, Show Tasks File, Quit.
struct NotchMenu: View {
    let store: TaskStore

    var body: some View {
        if LaunchAtLogin.needsApproval {
            Button("Launch at Login: approve in System Settings") { LaunchAtLogin.openSettings() }
        } else {
            Toggle("Launch at Login", isOn: Binding(
                get: { LaunchAtLogin.isEnabled },
                set: { on in
                    do {
                        let status = try LaunchAtLogin.setEnabled(on)
                        if status == .requiresApproval { LaunchAtLogin.openSettings() }
                    } catch {
                        NSSound.beep()
                    }
                }
            ))
        }
        Toggle("Sounds", isOn: Binding(
            get: { Sounds.enabled },
            set: { Sounds.enabled = $0 }
        ))
        Button("Show Tasks File") {
            NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
        }
        Divider()
        Button("Quit Main Thing") { NSApp.terminate(nil) }
    }
}

/// Sizes shared by the view and the width measurement.
enum NotchMetrics {
    static let font = Font.system(size: 13, weight: .medium)
    @MainActor static let nsFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    /// The current task in the open state.
    static let titleFont = Font.system(size: 15, weight: .semibold)
    @MainActor static let titleNSFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    /// The other tasks in the open state.
    static let rowFont = Font.system(size: 13)
    @MainActor static let rowNSFont = NSFont.systemFont(ofSize: 13)
    /// x-heights, for centering the done circle on the first line.
    @MainActor static let titleXHeight: CGFloat = titleNSFont.xHeight
    @MainActor static let rowXHeight: CGFloat = rowNSFont.xHeight
    static let textInset: CGFloat = 22
    static let flare = NotchGeometry.flare
    static let bottomRadius: CGFloat = 12
    static let openBottomRadius: CGFloat = 24
    static let maxWidth: CGFloat = 600

    /// Collapsed notch width before the flares. Follows the title, clamped.
    /// `minimum` comes from the geometry: plain 140, or the camera housing width.
    @MainActor static func width(for title: String?, minimum: CGFloat = NotchGeometry.housingWidth - 2 * NotchGeometry.flare) -> CGFloat {
        guard let title, !title.isEmpty else { return minimum }
        let text = (title as NSString).size(withAttributes: [.font: nsFont]).width
        return min(max(ceil(text) + textInset * 2, minimum), maxWidth)
    }
}

/// A notch outline: flared top corners that meet the screen edge, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.height / 2)
        let b = min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + t, y: rect.minY + t),
            control: CGPoint(x: rect.minX + t, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addArc(
            center: CGPoint(x: rect.minX + t + b, y: rect.maxY - b),
            radius: b, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true
        )
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addArc(
            center: CGPoint(x: rect.maxX - t - b, y: rect.maxY - b),
            radius: b, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true
        )
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - t, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}
