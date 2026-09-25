import AppKit
import MainThingCore
import SwiftUI
import os

/// The notch. Collapsed: a black shape at the top center with the current task inside.
/// Open: every task, the current one large, each with a done circle on row hover.
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

/// The rows, plain when they fit, in a scroll view with hidden indicators when they do not.
struct RowsBlock<Content: View>: View {
    let maxHeight: CGFloat?
    @ViewBuilder let content: Content

    var body: some View {
        if let maxHeight {
            ScrollView(.vertical) {
                content
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: maxHeight)
        } else {
            content
        }
    }
}

/// One task. The whole row is the button. The circle appears on row hover; a click strikes the
/// title through from left to right and dims it, and 250ms later the row leaves.
struct TaskRow: View {
    let row: TaskList.Row
    let isCurrent: Bool
    let struck: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let font = isCurrent ? NotchMetrics.titleFont : NotchMetrics.rowFont
        let halfXHeight = (isCurrent ? NotchMetrics.titleXHeight : NotchMetrics.rowXHeight) / 2
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: OpenLayout.circleGap) {
                DoneCircle(visible: hovering || struck, filled: struck)
                    // The circle's center sits on the x-height center of the title's first line,
                    // so it stays put when the title wraps to two lines.
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + halfXHeight }
                Text(row.title)
                    .font(font)
                    .foregroundStyle(.white.opacity(isCurrent ? 1 : NotchMetrics.dimOpacity))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .opacity(struck ? 0.45 : 1)
                    .overlay {
                        // The strike line alone, through every line of the title, revealed left to right.
                        Text(row.title)
                            .font(font)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .foregroundStyle(.clear)
                            .strikethrough(true, color: .white.opacity(0.9))
                            .mask(alignment: .leading) {
                                Rectangle().scaleEffect(x: struck ? 1 : 0.001, anchor: .leading)
                            }
                            .opacity(struck ? 1 : 0)
                            .allowsHitTesting(false)
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? Motion.reducedFade : Motion.strike, value: struck)
        .accessibilityLabel(row.title)
        .accessibilityHint(struck ? "Done, leaving" : "Mark done")
    }
}

/// Right click menu: Launch at Login, Show Tasks File, Quit.
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
        Button("Show Tasks File") {
            NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
        }
        Divider()
        Button("Quit Main Thing") { NSApp.terminate(nil) }
    }
}

/// The circle that marks a row done. Shown only while the cursor is on the row; its 22pt space
/// stays reserved so the title never shifts. Pops in from 0.85, grows to 1.1 under the cursor,
/// bounces to 1.15 as it fills.
struct DoneCircle: View {
    let visible: Bool
    let filled: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Never from 0. A scale bounce, not symbolEffect(.bounce): that one left the symbol blank in this panel.
        let scale: CGFloat = reduceMotion ? 1 : (!visible ? 0.85 : (filled ? 1.15 : (hovering ? 1.1 : 1)))
        Image(systemName: filled ? "checkmark.circle.fill" : (hovering ? "checkmark.circle" : "circle"))
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(.white.opacity(filled ? 1 : 0.6))
            .contentTransition(Motion.symbol(reduceMotion))
            .frame(width: OpenLayout.circleWidth, height: OpenLayout.circleWidth)
            .contentShape(Rectangle())
            .opacity(visible ? 1 : 0)
            .scaleEffect(scale)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? Motion.reducedFade : Motion.popSpring, value: visible)
            .animation(reduceMotion ? Motion.reducedFade : Motion.bounceSpring, value: hovering)
            .animation(reduceMotion ? Motion.reducedFade : Motion.bounceSpring, value: filled)
            .accessibilityHidden(true)
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
    /// The other tasks are dimmed to this.
    static let dimOpacity: Double = 0.55
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
