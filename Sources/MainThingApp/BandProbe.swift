import AppKit
import MainThingCore
import SwiftUI

/// `MainThing --probe-band`: the closed notch under a hardware notch, read back from the rendered
/// view (the hosting view drawn into a bitmap, as the screen would show it). It never shows a
/// window: the real notch view runs in an invisible panel, on a list in memory, and the cursor stays.
///
/// 1. One task: the notch is hidden, as it always is under a hardware notch, and the dot is within
///    0.5pt of the left wing's middle.
/// 2. An empty list: the shape is the camera's width and the menu bar row tall, with rounded bottom
///    corners (the corner pixel is clear, the pixel 12pt in along the bottom edge is black), flares
///    at the top, and every pixel inside it is opaque black.
///
/// Exits 0 when both hold, 5 when not. The fixture is a 14 inch MacBook Pro.
@MainActor
enum BandProbe {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main else {
            print("probe-band: no screen")
            exit(1)
        }
        let geometry = NotchGeometry(screen: HoverBench.fixtures["notch"] ?? ScreenInfo(screen))
        Task { @MainActor in
            var failed = false
            failed = await !closedDot(geometry: geometry, screen: screen) || failed
            failed = await !emptyShape(geometry: geometry, screen: screen) || failed
            print(failed ? "probe-band: FAIL" : "probe-band: all band checks passed")
            exit(failed ? 5 : 0)
        }
        app.run()
        exit(0)
    }

    /// The notch view for `titles`, closed, laid out and drawn.
    private static func render(titles: [String], geometry: NotchGeometry, screen: NSScreen) async -> (rep: NSBitmapImageRep, model: NotchModel, scale: CGFloat)? {
        let store = TaskStore(previewTitles: titles)
        let model = NotchModel(geometry: geometry, apiPort: APIPort.preferred)
        let size = NotchGeometry.panelSize
        let panel = NotchPanel(contentRect: CGRect(origin: screen.frame.origin, size: size))
        panel.alphaValue = 0
        let hosting = NotchHostingView(rootView: NotchView(store: store, model: model))
        panel.contentView = hosting
        panel.orderFrontRegardless()
        // Let the layout and any spring settle.
        try? await Task.sleep(for: .milliseconds(800))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        panel.close()
        return (rep, model, CGFloat(rep.pixelsWide) / hosting.bounds.width)
    }

    private static func ink(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        rep.colorAt(x: x, y: y)?.whiteComponentValue ?? 0
    }

    /// One task, closed, under a hardware notch: always hidden, so no title, and the dot centered
    /// in the left wing of the menu bar row.
    private static func closedDot(geometry: NotchGeometry, screen: NSScreen) async -> Bool {
        guard let (rep, model, scale) = await render(titles: ["HEH"], geometry: geometry, screen: screen) else {
            print("probe-band: could not draw the view")
            return false
        }
        let rect = geometry.hiddenRect
        let wantX = rect.minX + geometry.hiddenDotX, wantY = rect.height / 2
        // The dot: its saturated core, a box around it, searched in the whole hidden row.
        var top = Int.max, bottom = -1, left = Int.max, right = -1
        for y in 0..<Int(rect.height * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.8, color.greenComponent < 0.5, color.blueComponent > 0.4 {
                    top = min(top, y); bottom = max(bottom, y); left = min(left, x); right = max(right, x)
                }
            }
        }
        let dotX = right >= 0 ? CGFloat(left + right + 1) / 2 / scale : -1
        let dotY = bottom >= 0 ? CGFloat(top + bottom + 1) / 2 / scale : -1
        print(String(format: "probe-band: hidden %@, row %.0fpt tall; dot at %.2f, %.2f, want %.2f, %.2f",
                     model.hidden ? "yes" : "no", rect.height, dotX, dotY, wantX, wantY))
        var ok = true
        if !model.hidden { print("probe-band: FAIL the closed notch is not hidden under a hardware notch"); ok = false }
        if abs(dotX - wantX) > 0.5 || abs(dotY - wantY) > 0.5 { print("probe-band: FAIL the dot is more than 0.5pt from the left wing's middle"); ok = false }
        return ok
    }

    private static func emptyShape(geometry: NotchGeometry, screen: NSScreen) async -> Bool {
        guard let (rep, _, scale) = await render(titles: [], geometry: geometry, screen: screen) else {
            print("probe-band: could not draw the view")
            return false
        }
        let f = NotchGeometry.flare
        let left = (NotchGeometry.panelSize.width - geometry.emptyWidth) / 2
        let right = left + geometry.emptyWidth
        let bottom = geometry.hiddenHeight
        let r = NotchGeometry.closedBottomRadius
        func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat { rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.alphaComponent ?? -1 }
        let corner = alpha(left + 0.3, bottom - 0.3), cornerRight = alpha(right - 0.3, bottom - 0.3)
        let along = alpha(left + r + 1, bottom - 0.3), middle = alpha(NotchGeometry.panelSize.width / 2, bottom / 2)
        let flare = alpha(left - f / 2, 0.3), flareRight = alpha(right + f / 2, 0.3)
        let below = alpha(NotchGeometry.panelSize.width / 2, bottom + 1)
        // Every pixel in the shape's straight part is opaque black.
        var solid = true
        for y in stride(from: 0.5, to: bottom - r, by: 1.0) {
            for x in stride(from: left + 1, to: right - 1, by: 1.0) {
                let color = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB)
                if (color?.alphaComponent ?? 0) < 0.999 || (color?.redComponent ?? 1) > 0.01 { solid = false }
            }
        }
        print(String(format: "probe-band: empty list, %.1fpt wide, %.0fpt tall; bottom corners %.2f and %.2f, bottom edge %.2f, flares %.2f and %.2f, below %.2f, solid black %@",
                     geometry.emptyWidth, bottom, corner, cornerRight, along, flare, flareRight, below, solid ? "yes" : "no"))
        var ok = true
        if corner > 0.5 || cornerRight > 0.5 { print("probe-band: FAIL the empty shape's bottom corners are square"); ok = false }
        if along < 0.99 || middle < 0.99 { print("probe-band: FAIL the empty shape's bottom edge is not drawn"); ok = false }
        if flare < 0.5 || flareRight < 0.5 { print("probe-band: FAIL the empty shape has no flares at the top"); ok = false }
        if below > 0.01 { print("probe-band: FAIL the empty shape draws below the menu bar row"); ok = false }
        if !solid { print("probe-band: FAIL the empty shape is not opaque black"); ok = false }
        return ok
    }
}
