import CoreGraphics
import Foundation

/// One line in the list editor. `id` is the editor's own identity for the row, stable across
/// moves and renames; `ref` is carried over from the task the row came from and stays hidden.
public struct DraftRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var ref: String?

    public init(id: UUID = UUID(), title: String, ref: String? = nil) {
        self.id = id
        self.title = title
        self.ref = ref
    }
}

/// The list editor's working copy. `base` is the list as it was when the editor opened; `rows`
/// is what the person made of it. Pure: the app applies `result()` with source `editor`, which is
/// a replace, so a removed row is deleted and never completed (no adapter, no `task-completed`).
public struct EditorDraft: Equatable, Sendable {
    public private(set) var rows: [DraftRow]
    /// The live list when the editor opened.
    public let base: [TaskItem]

    public init(_ tasks: [TaskItem]) {
        base = tasks
        rows = tasks.map { DraftRow(title: $0.title, ref: $0.ref) }
    }

    public init(rows: [DraftRow], base: [TaskItem]) {
        self.rows = rows
        self.base = base
    }

    public func index(of id: UUID) -> Int? {
        rows.firstIndex { $0.id == id }
    }

    /// Moves the row at `from` so it ends up at index `to`. Out of range indices are clamped;
    /// a `from` outside the rows does nothing.
    public mutating func move(from: Int, to: Int) {
        guard rows.indices.contains(from) else { return }
        let row = rows.remove(at: from)
        rows.insert(row, at: min(max(to, 0), rows.count))
    }

    /// A new blank row right below `id` (at the top for nil, at the end for an id not here).
    /// New rows have no ref. Returns the new row's id, for focus.
    @discardableResult
    public mutating func insert(after id: UUID?, title: String = "") -> UUID {
        let row = DraftRow(title: title)
        if let id {
            rows.insert(row, at: index(of: id).map { $0 + 1 } ?? rows.count)
        } else {
            rows.insert(row, at: 0)
        }
        return row.id
    }

    /// Removes the row. Returns the row that should take focus: the one above, or the new first
    /// row when the first was removed, or nil when none is left or `id` was not here.
    @discardableResult
    public mutating func remove(id: UUID) -> UUID? {
        guard let i = index(of: id) else { return nil }
        rows.remove(at: i)
        if rows.isEmpty { return nil }
        return rows[max(i - 1, 0)].id
    }

    /// A new title for the row. Its ref stays, so the task is still the same task in its tool.
    public mutating func rename(id: UUID, title: String) {
        guard let i = index(of: id) else { return }
        rows[i].title = title
    }

    /// The list to save: titles trimmed, blank rows dropped, refs kept on the rows that had them.
    public func result() -> [TaskItem] {
        TaskList.clean(rows.map { TaskItem($0.title, ref: $0.ref) })
    }

    /// The live list moved on since the editor opened (an agent or the API wrote to it).
    public func conflict(current: [TaskItem]) -> Bool {
        current != base
    }

    /// Saving would change something compared with the list the editor opened on.
    public var isEdited: Bool {
        result() != TaskList.clean(base)
    }
}

/// Sizes of the list editor window. The rows use the card's lanes (`Lanes`), so a row in the
/// editor reads like a row in the open notch. Points at 1x, origin top left for positions.
public enum EditorLayout {
    public static let width: CGFloat = 360
    public static let radius: CGFloat = 24
    /// Rows past this many scroll.
    public static let maxVisibleRows = 12
    public static let rowHeight: CGFloat = Lanes.rowHeight
    public static let topPadding: CGFloat = 12
    /// Between the last row and the buttons.
    public static let footerGap: CGFloat = 8
    public static let buttonHeight: CGFloat = 26
    public static let bottomPadding: CGFloat = 12
    /// The conflict message line above Reload and Overwrite.
    public static let messageHeight: CGFloat = 18
    public static let messageGap: CGFloat = 6
    /// Default spot: centered under the notch, this far below its bottom edge.
    public static let gapBelowNotch: CGFloat = 10
    /// A window that is off screen by more than this is pulled back in.
    public static let screenMargin: CGFloat = 8

    /// The rows block height: every row up to `maxVisibleRows`, then it scrolls.
    public static func rowsHeight(rows: Int) -> CGFloat {
        CGFloat(min(max(rows, 1), maxVisibleRows)) * rowHeight
    }

    public static func scrolls(rows: Int) -> Bool { rows > maxVisibleRows }

    public static func footerHeight(conflict: Bool) -> CGFloat {
        buttonHeight + (conflict ? messageHeight + messageGap : 0)
    }

    public static func height(rows: Int, conflict: Bool = false) -> CGFloat {
        topPadding + rowsHeight(rows: rows) + footerGap + footerHeight(conflict: conflict) + bottomPadding
    }

    /// The default top left corner, centered on `centerX`, under a notch whose bottom edge is at
    /// `notchBottom`. Screen coordinates with y growing down.
    public static func defaultTopLeft(centerX: CGFloat, notchBottom: CGFloat) -> CGPoint {
        CGPoint(x: (centerX - width / 2).rounded(), y: notchBottom + gapBelowNotch)
    }

    /// Moves `frame` (y growing down) fully into `visible`, keeping its size when it fits.
    public static func clamp(_ frame: CGRect, into visible: CGRect) -> CGRect {
        var f = frame
        let inner = visible.insetBy(dx: screenMargin, dy: screenMargin)
        if f.maxX > inner.maxX { f.origin.x = inner.maxX - f.width }
        if f.minX < inner.minX { f.origin.x = inner.minX }
        if f.maxY > inner.maxY { f.origin.y = inner.maxY - f.height }
        if f.minY < inner.minY { f.origin.y = inner.minY }
        return f
    }
}
