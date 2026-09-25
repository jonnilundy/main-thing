import AppKit
import NextUpCore
import SwiftUI

/// The notch. Collapsed: a black shape at the top center with the current task inside.
/// Open: the current task large with a done circle, the next three, and a "+N more" line.
struct NotchView: View {
    let store: TaskStore
    let model: NotchModel
    var onDone: () -> Void = {}
    @Namespace private var titleSpace

    var body: some View {
        VStack(spacing: 0) {
            NotchBody(store: store, model: model, onDone: onDone, titleSpace: titleSpace)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ShapeRectKey.self, value: proxy.frame(in: .named("panel")))
                    }
                )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: "panel")
        .onPreferenceChange(ShapeRectKey.self) { rect in
            MainActor.assumeIsolated { model.shapeRect = rect }
        }
    }
}

private struct ShapeRectKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct NotchBody: View {
    let store: TaskStore
    let model: NotchModel
    let onDone: () -> Void
    let titleSpace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rows = store.list.rows
        let keys = rows.map(\.key)
        let title = rows.first?.title
        let geometry = model.geometry
        let collapsedWidth = NotchMetrics.width(for: title, minimum: geometry.minimumWidth)
        let width = model.isOpen ? max(collapsedWidth, NotchMetrics.openWidth) : collapsedWidth
        let shape = NotchShape(
            topRadius: NotchMetrics.flare,
            bottomRadius: model.isOpen ? NotchMetrics.openBottomRadius : NotchMetrics.bottomRadius
        )
        VStack(spacing: 0) {
            // The notch row: the menu bar row, or the camera housing plus the title band under it.
            ZStack(alignment: .bottom) {
                if !model.isOpen, let current = rows.first {
                    Text(current.title)
                        .font(NotchMetrics.font)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, NotchMetrics.textInset)
                        .frame(height: geometry.titleBandHeight)
                        .matchedGeometryEffect(id: "title", in: titleSpace)
                        .id(current.key)
                        .transition(Motion.push(reduceMotion))
                }
            }
            .frame(width: width, height: geometry.notchHeight)
            .animation(Motion.content(reduceMotion), value: keys)
            if model.isOpen {
                OpenContent(store: store, model: model, onDone: onDone, titleSpace: titleSpace)
                    .frame(width: width)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, NotchMetrics.flare)
        .background(shape.fill(.black))
        .clipShape(shape)
        .animation(Motion.shape(reduceMotion), value: model.isOpen)
        .animation(Motion.shape(reduceMotion), value: keys)
        .accessibilityLabel(title ?? "No task")
    }
}

struct OpenContent: View {
    let store: TaskStore
    let model: NotchModel
    let onDone: () -> Void
    let titleSpace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rows = store.list.rows
        let keys = rows.map(\.key)
        VStack(alignment: .leading, spacing: 6) {
            if let current = rows.first {
                HStack(alignment: .top, spacing: 10) {
                    DoneButton(armed: model.doneArmed, action: onDone)
                        .padding(.top, 1)
                    Text(current.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .matchedGeometryEffect(id: "title", in: titleSpace)
                        .id(current.key)
                        .transition(Motion.push(reduceMotion))
                }
                ForEach(rows.dropFirst().prefix(3)) { row in
                    Text(row.title)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .padding(.leading, NotchMetrics.rowIndent)
                        .transition(Motion.push(reduceMotion))
                }
                if rows.count > 4 {
                    Text("+\(rows.count - 4) more")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.leading, NotchMetrics.rowIndent)
                        .transition(.opacity)
                }
            } else {
                Text("No tasks")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .transition(.opacity)
            }
            if !model.apiBound {
                Text("API off on port " + String(model.apiPort))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.content(reduceMotion), value: keys)
    }
}

/// The circle that completes the current task.
struct DoneButton: View {
    let armed: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: armed ? "checkmark.circle.fill" : (hovering ? "checkmark.circle" : "circle"))
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white.opacity(armed ? 1 : 0.6))
                .contentTransition(Motion.symbol(reduceMotion))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.content(reduceMotion), value: armed)
        .animation(Motion.content(reduceMotion), value: hovering)
        .accessibilityLabel("Done")
    }
}

/// Sizes shared by the view and the width measurement.
enum NotchMetrics {
    static let font = Font.system(size: 13, weight: .medium)
    @MainActor static let nsFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let textInset: CGFloat = 22
    static let flare = NotchGeometry.flare
    static let bottomRadius: CGFloat = 12
    static let openBottomRadius: CGFloat = 24
    static let maxWidth: CGFloat = 600
    static let openWidth: CGFloat = 420
    static let rowIndent: CGFloat = 32

    /// Collapsed notch width before the flares. Follows the title, clamped.
    /// `minimum` comes from the geometry: plain 140, or the camera housing width.
    @MainActor static func width(for title: String?, minimum: CGFloat = NotchGeometry.plainMinimumWidth) -> CGFloat {
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
