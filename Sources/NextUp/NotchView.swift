import AppKit
import SwiftUI

/// The collapsed notch: a black shape at the top center with the current title inside.
struct NotchView: View {
    var title: String?
    var notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            NotchBody(title: title, height: notchHeight)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct NotchBody: View {
    var title: String?
    var height: CGFloat

    var body: some View {
        let width = NotchMetrics.width(for: title)
        ZStack {
            if let title, !title.isEmpty {
                Text(title)
                    .font(NotchMetrics.font)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, NotchMetrics.textInset)
            }
        }
        .frame(width: width, height: height)
        .padding(.horizontal, NotchMetrics.flare)
        .background(
            NotchShape(topRadius: NotchMetrics.flare, bottomRadius: NotchMetrics.bottomRadius)
                .fill(.black)
        )
        .accessibilityLabel(title ?? "No task")
    }
}

/// Sizes shared by the view and the width measurement.
enum NotchMetrics {
    static let font = Font.system(size: 13, weight: .medium)
    @MainActor static let nsFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let textInset: CGFloat = 22
    static let flare: CGFloat = 8
    static let bottomRadius: CGFloat = 12
    static let minWidth: CGFloat = 140
    static let maxWidth: CGFloat = 600

    /// Notch width before the flares. Follows the title, clamped.
    @MainActor static func width(for title: String?) -> CGFloat {
        guard let title, !title.isEmpty else { return minWidth }
        let text = (title as NSString).size(withAttributes: [.font: nsFont]).width
        return min(max(ceil(text) + textInset * 2, minWidth), maxWidth)
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
