import AppKit
import MainThingCore

/// Sizes the open card and the panel around it from the list, with the fonts the rows draw with.
///
/// The panel is transparent, so it is resized instantly before the shape animates: tall enough
/// for every row plus the bounce, up to 60 percent of the screen. Past that the rows scroll.
/// The click through hit test keeps using the visible shape, so a tall panel blocks nothing.
@MainActor
final class PanelLayout {
    private let panel: NSPanel
    private let model: NotchModel
    private let store: TaskStore
    private var shrink: Task<Void, Never>?

    init(panel: NSPanel, model: NotchModel, store: TaskStore) {
        self.panel = panel
        self.model = model
        self.store = store
    }

    /// Measures the list, sets the card width and the scroll limit on the model, and grows the
    /// panel to fit. Called right before the notch opens and on every list change while open.
    func fitOpen() {
        shrink?.cancel()
        shrink = nil
        let geometry = model.geometry
        let rows = store.list.rows
        let fonts = rows.indices.map { $0 == 0 ? NotchMetrics.titleNSFont : NotchMetrics.rowNSFont }
        let widths = zip(rows, fonts).map { PanelLayout.width(of: $0.title, font: $1) }
        let width = OpenLayout.width(titleWidths: widths, screenWidth: geometry.screenFrame.width)
        let titleWidth = OpenLayout.titleWidth(contentWidth: width)
        let heights = zip(rows, fonts).map { row, font in
            PanelLayout.height(of: row.title, font: font, width: titleWidth, lines: OpenLayout.maxLines)
        }
        let notes = (model.apiBound ? 0 : 1) + store.events.failing.count
        let content = OpenLayout.contentHeight(rowHeights: heights, notes: notes)
        let fit = OpenLayout.panelHeight(
            notchHeight: geometry.notchHeight, contentHeight: content,
            screenHeight: geometry.screenFrame.height, minimum: NotchGeometry.panelSize.height
        )
        model.openWidth = width
        model.rowsMaxHeight = fit.rowsMax
        let frame = geometry.panelFrame(height: fit.panel)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            // Lay the content out at the new size now. Otherwise the shape rect is reported once
            // from the old layout in the new coordinates, and the hover test closes the notch again.
            panel.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// After the close animation, back to the default panel size.
    func fitClosed() {
        shrink?.cancel()
        shrink = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled, !model.isOpen else { return }
            let frame = model.geometry.panelFrame
            if panel.frame != frame { panel.setFrame(frame, display: false) }
        }
    }

    /// Single line width of a title in a font.
    static func width(of title: String, font: NSFont) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }

    /// How many lines a title takes at `width`, capped at `OpenLayout.maxLines`.
    static func lineCount(of title: String, font: NSFont, width: CGFloat) -> Int {
        let line = ceil(font.ascender - font.descender + font.leading)
        let height = PanelLayout.height(of: title, font: font, width: width, lines: OpenLayout.maxLines)
        return max(1, min(OpenLayout.maxLines, Int((height / line).rounded())))
    }

    /// Height of a title wrapped at `width`, at most `lines` lines.
    static func height(of title: String, font: NSFont, width: CGFloat, lines: Int) -> CGFloat {
        let bounds = (title as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let line = ceil(font.ascender - font.descender + font.leading)
        return min(ceil(bounds.height), line * CGFloat(lines))
    }
}
