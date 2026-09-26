import CoreGraphics
import Foundation

/// What a point on the open card is over. `task` carries the list index: 0 is the band.
public enum CardSlot: Equatable, Hashable, Sendable {
    case task(Int)
    /// The Undo left where a discarded task was.
    case undo
    /// The add card at the very bottom.
    case add
    /// The "No tasks" line, a note line, or off the card.
    case none
}

/// The open card's slots from top to bottom, and which one a point is over. Pure; the app hands
/// in the list's shape and the pointer in card coordinates: y from the card's top edge, x from
/// the body edge (the flare left out).
///
/// Top to bottom: the band (task 1), the gap, the rows (tasks 2..N, with the Undo slot in place of
/// a discarded task), the note lines, the add card, the bottom padding. Every height belongs to a
/// slot: a gap between two slots is split at its middle, so moving down never crosses a spot with
/// no hover. The rows scroll past `rowsMax`; `scroll` is how far.
public struct CardMap: Equatable, Sendable {
    public var notchHeight: CGFloat
    public var taskCount: Int
    /// Position under the band (0 is the first row) where the Undo shows, or nil.
    public var undoRow: Int?
    public var notesHeight: CGFloat
    public var rowsMax: CGFloat?
    public var scroll: CGFloat
    /// The add card shows (hovered, or its field open). Folded, its slot is only the bottom
    /// padding: the card keeps no blank row, and hovering the padding unfolds it.
    public var addOpen: Bool

    public init(notchHeight: CGFloat, taskCount: Int, undoRow: Int? = nil, notesHeight: CGFloat = 0, rowsMax: CGFloat? = nil, scroll: CGFloat = 0, addOpen: Bool = false) {
        self.notchHeight = notchHeight
        self.taskCount = max(taskCount, 0)
        self.undoRow = undoRow
        self.notesHeight = notesHeight
        self.rowsMax = rowsMax
        self.scroll = scroll
        self.addOpen = addOpen
    }

    public var rowsTop: CGFloat { notchHeight + Lanes.topGap }
    /// Rows under the band: tasks 2..N, plus the Undo slot.
    public var rowItems: Int { max(taskCount - 1, 0) + (undoRow == nil ? 0 : 1) }
    /// No task and no Undo: the "No tasks" line.
    public var isEmpty: Bool { taskCount == 0 && undoRow == nil }
    public var rowsHeight: CGFloat { isEmpty ? OpenLayout.emptyHeight : CGFloat(rowItems) * Lanes.rowHeight }
    public var rowsVisibleHeight: CGFloat { rowsMax.map { min($0, rowsHeight) } ?? rowsHeight }
    public var addTop: CGFloat { rowsTop + rowsVisibleHeight + notesHeight }
    /// The card's full height, band included.
    public var height: CGFloat { addTop + addHeight + Lanes.bottomPadding }
    /// The add card's row: a row tall when it shows, nothing when folded into the padding.
    public var addHeight: CGFloat { addOpen ? OpenLayout.addHeight : 0 }

    /// The Undo's position, clamped into the rows.
    public var undoPosition: Int? { undoRow.map { min(max($0, 0), max(rowItems - 1, 0)) } }

    /// What the row at `position` under the band holds.
    public func item(atRow position: Int) -> CardSlot {
        guard position >= 0, position < rowItems else { return .none }
        guard let undo = undoPosition else { return .task(position + 1) }
        if position == undo { return .undo }
        return .task(position < undo ? position + 1 : position)
    }

    /// The row position under the band of task `index` (nil for the band or a task not there).
    public func position(ofTask index: Int) -> Int? {
        guard index >= 1, index < taskCount else { return nil }
        guard let undo = undoPosition else { return index - 1 }
        return index - 1 < undo ? index - 1 : index
    }

    private enum Kind { case band, rows, none, add }

    private var regions: [(top: CGFloat, bottom: CGFloat, kind: Kind)] {
        var list: [(top: CGFloat, bottom: CGFloat, kind: Kind)] = []
        if taskCount > 0 { list.append((0, notchHeight, .band)) }
        if isEmpty {
            list.append((rowsTop, rowsTop + OpenLayout.emptyHeight, .none))
        } else if rowItems > 0 {
            list.append((rowsTop, rowsTop + rowsVisibleHeight, .rows))
        }
        if notesHeight > 0 { list.append((rowsTop + rowsVisibleHeight, addTop, .none)) }
        list.append((addTop, height, .add))
        return list
    }

    /// The slot under a point `y` from the card's top. Above the first slot is the first; below
    /// the last is the add card.
    public func slot(atY y: CGFloat) -> CardSlot {
        let regions = self.regions
        var chosen = regions[0]
        for (index, region) in regions.enumerated() {
            let next = index + 1 < regions.count ? regions[index + 1] : nil
            // The boundary with the next slot: the middle of the gap between them.
            let boundary = next.map { (region.bottom + $0.top) / 2 } ?? .infinity
            chosen = region
            if y < boundary { break }
        }
        switch chosen.kind {
        case .band: return .task(0)
        case .add: return .add
        case .none: return .none
        case .rows:
            let offset = y - chosen.top + scroll
            let position = min(max(Int((offset / Lanes.rowHeight).rounded(.down)), 0), rowItems - 1)
            return item(atRow: position)
        }
    }

    /// The vertical center of task `index`'s resting place, card coordinates. The band for 0.
    /// Used while dragging, when no Undo shows.
    public func center(ofTask index: Int) -> CGFloat {
        if index <= 0 { return notchHeight / 2 }
        return rowsTop + (CGFloat(index - 1) + 0.5) * Lanes.rowHeight - scroll
    }

    public var taskCenters: [CGFloat] { (0..<taskCount).map(center(ofTask:)) }

    /// The vertical center of a slot as laid out now, the Undo row included.
    public func centerY(of slot: CardSlot) -> CGFloat {
        let row: Int
        switch slot {
        case .task(0): return notchHeight / 2
        case .task(let index): guard let p = position(ofTask: index) else { return notchHeight / 2 }; row = p
        case .undo: guard let p = undoPosition else { return rowsTop }; row = p
        case .add: return addTop + (addHeight + Lanes.bottomPadding) / 2
        case .none: return rowsTop
        }
        return rowsTop + (CGFloat(row) + 0.5) * Lanes.rowHeight - scroll
    }

    /// Every task's center as laid out now: the reorder targets. An Undo row keeps its place.
    public var liveCenters: [CGFloat] { (0..<taskCount).map { centerY(of: .task($0)) } }

    /// The drag handle lane: the dot's and the numbers' lane, with the gutter left of it and half
    /// the gap to the title. A press there and a drag reorders; anywhere else it does not.
    public static func inHandle(x: CGFloat) -> Bool {
        x >= 0 && x < Lanes.textStart - Lanes.gap / 2
    }
}

/// Reordering by drag. The dragged task follows the pointer; the others make room.
public enum Reorder {
    /// The list index the dragged task would land on: the resting place whose center is nearest
    /// the dragged task's center, `offset` points from its own.
    public static func target(from: Int, offset: CGFloat, centers: [CGFloat]) -> Int {
        guard centers.indices.contains(from) else { return from }
        let y = centers[from] + offset
        var best = from
        for (index, center) in centers.enumerated() where abs(center - y) < abs(centers[best] - y) {
            best = index
        }
        return best
    }

    /// Where task `index` shows while `from` is held over `to`: the tasks in between move one
    /// place toward `from`.
    public static func place(of index: Int, from: Int, to: Int) -> Int {
        if index == from { return to }
        if from < to, index > from, index <= to { return index - 1 }
        if to < from, index >= to, index < from { return index + 1 }
        return index
    }

    public static func move<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard items.indices.contains(from) else { return items }
        var result = items
        let item = result.remove(at: from)
        result.insert(item, at: min(max(to, 0), result.count))
        return result
    }
}

/// One press on the open card, from mouse down to mouse up: a click, a long press, a reorder
/// drag, or a drag that is none of those. Pure; the app feeds in positions and acts on the kind.
public struct CardPress: Equatable, Sendable {
    /// A move shorter than this is still a click.
    public static let slop: CGFloat = 3

    public enum Kind: Equatable, Sendable {
        /// Down and still: a click on release, a long press when held.
        case pressed
        /// Held long enough: the menu is open. The release is no click.
        case longPressed
        /// Started on the handle and moved: the task follows the pointer.
        case reordering
        /// Moved away from anywhere else: the release does nothing.
        case moved
    }

    public let slot: CardSlot
    public let start: CGPoint
    /// Pressed in the handle lane of a task.
    public let onHandle: Bool
    public private(set) var kind: Kind = .pressed
    public private(set) var offset: CGSize = .zero

    public init(slot: CardSlot, start: CGPoint, onHandle: Bool) {
        self.slot = slot
        self.start = start
        if case .task = slot { self.onHandle = onHandle } else { self.onHandle = false }
    }

    @discardableResult
    public mutating func move(to point: CGPoint) -> Kind {
        offset = CGSize(width: point.x - start.x, height: point.y - start.y)
        if kind == .pressed, hypot(offset.width, offset.height) >= CardPress.slop {
            kind = onHandle ? .reordering : .moved
        }
        return kind
    }

    /// The long press time ran out. True when that opens the menu: still down, still in place, on a task.
    public mutating func held() -> Bool {
        guard kind == .pressed, case .task = slot else { return false }
        kind = .longPressed
        return true
    }

    /// The slot a release clicks, or nil when it is no click.
    public var click: CardSlot? { kind == .pressed ? slot : nil }

    /// The system long press time: the double click interval, 0.5s by default, kept in 0.3...1s.
    public static func longPressDuration(doubleClickInterval: TimeInterval) -> TimeInterval {
        min(max(doubleClickInterval, 0.3), 1)
    }
}

/// The long press menu: Rename and Discard side by side, a small pill inside the pressed row.
public enum RowMenu {
    public enum Item: String, CaseIterable, Sendable {
        case rename = "Rename"
        case discard = "Discard"
    }

    public static let itemWidth: CGFloat = 62
    public static let height: CGFloat = 22
    public static let padding: CGFloat = 2
    public static var width: CGFloat { CGFloat(Item.allCases.count) * itemWidth + 2 * padding }

    /// Space between the press and the menu, so the release where the press was selects nothing.
    public static let offset: CGFloat = 6

    /// The menu's frame, card coordinates: centered on the row, just right of the press, or just
    /// left of it where the pill has no room on the right, and kept inside the row's pill.
    public static func frame(pressX: CGFloat, rowCenterY: CGFloat, cardWidth: CGFloat) -> CGRect {
        let low = Lanes.pillInset + 2
        let high = max(cardWidth - Lanes.pillInset - 2 - width, low)
        let right = pressX + offset
        let x = right <= high ? right : pressX - offset - width
        return CGRect(x: min(max(x, low), high).rounded(), y: (rowCenterY - height / 2).rounded(), width: width, height: height)
    }

    /// The item under a point, card coordinates.
    public static func item(at point: CGPoint, in frame: CGRect) -> Item? {
        guard frame.contains(point) else { return nil }
        let index = Int(((point.x - frame.minX - padding) / itemWidth).rounded(.down))
        return Item.allCases[min(max(index, 0), Item.allCases.count - 1)]
    }
}

/// A task discarded from the long press menu: deleted with no done hook, and an Undo shows in its
/// place for `seconds`. Undo puts it back where it was.
public struct Discarded: Equatable, Sendable {
    public static let seconds: TimeInterval = 4

    public let task: TaskItem
    /// Its list index when it was discarded.
    public let index: Int
    public let at: TimeInterval

    public init(task: TaskItem, index: Int, at: TimeInterval) {
        self.task = task
        self.index = index
        self.at = at
    }

    public func expired(at now: TimeInterval) -> Bool { now - at >= Discarded.seconds }

    /// Where the Undo shows under the band: its own row, or the first row for the main task.
    public var undoRow: Int { max(index - 1, 0) }

    /// `tasks` with the task back at its old index, or at the end when the list got shorter.
    /// A task with a ref that is in the list again is not added twice.
    public func restored(into tasks: [TaskItem]) -> [TaskItem] {
        if let ref = task.ref, tasks.contains(where: { $0.ref == ref }) { return tasks }
        var result = tasks
        result.insert(task, at: min(max(index, 0), result.count))
        return result
    }
}

/// Edits from the open card, by row key, so a list that changed since the gesture started still
/// gets the edit on the right task. Each returns the new list for `replace`, or nil for no change.
extension TaskList {
    /// The task `key` moved to index `to`.
    public func moving(key: String, to: Int) -> [TaskItem]? {
        guard let from = rows.firstIndex(where: { $0.key == key }) else { return nil }
        let to = min(max(to, 0), rows.count - 1)
        guard to != from else { return nil }
        return Reorder.move(tasks, from: from, to: to)
    }

    /// The task `key` with a new title and the same ref. A blank title changes nothing.
    public func renaming(key: String, to title: String) -> [TaskItem]? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let i = rows.firstIndex(where: { $0.key == key }), rows[i].title != title else { return nil }
        var result = tasks
        result[i].title = title
        return result
    }

    /// The list without the task `key`, and what Undo needs to put it back.
    public func discarding(key: String, at now: TimeInterval) -> (tasks: [TaskItem], discarded: Discarded)? {
        guard let i = rows.firstIndex(where: { $0.key == key }) else { return nil }
        var result = tasks
        let task = result.remove(at: i)
        return (result, Discarded(task: task, index: i, at: now))
    }

    /// A new task at the end. A blank title adds nothing.
    public func appending(_ title: String) -> [TaskItem]? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return tasks + [TaskItem(title)]
    }
}
