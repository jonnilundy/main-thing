import Foundation

/// The ordered task list. Index 0 is the current task.
///
/// On disk and on the wire this is `[String]`. In memory each title carries an
/// occurrence number so SwiftUI rows keep their identity across a done and
/// across a replace that touches other titles. Duplicate titles get different keys.
public struct TaskList: Equatable, Sendable {
    public struct Row: Identifiable, Hashable, Sendable {
        public let title: String
        public let occurrence: Int

        /// Stable identity: title plus occurrence, for example "Write memo#0".
        public var key: String { "\(title)#\(occurrence)" }
        public var id: String { key }
    }

    public private(set) var rows: [Row]

    public init(_ titles: [String] = []) {
        rows = []
        replace(titles)
    }

    public var titles: [String] { rows.map(\.title) }
    public var current: String? { rows.first?.title }
    public var isEmpty: Bool { rows.isEmpty }
    public var count: Int { rows.count }

    /// Trims every title and drops the blank ones.
    public static func clean(_ titles: [String]) -> [String] {
        titles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Replaces the whole list. Rows whose title is still present keep their key.
    /// New titles get the lowest occurrence number not in use for that title.
    public mutating func replace(_ newTitles: [String]) {
        var pool = rows
        var used: [String: Set<Int>] = [:]
        for row in pool {
            used[row.title, default: []].insert(row.occurrence)
        }
        var result: [Row] = []
        for title in TaskList.clean(newTitles) {
            if let i = pool.firstIndex(where: { $0.title == title }) {
                result.append(pool.remove(at: i))
            } else {
                var n = 0
                while used[title, default: []].contains(n) { n += 1 }
                used[title, default: []].insert(n)
                result.append(Row(title: title, occurrence: n))
            }
        }
        rows = result
    }

    /// Removes the current task. When `expected` is given, it must equal the
    /// current title, so a stale done from the UI cannot remove the wrong task.
    /// Returns true when the list changed.
    @discardableResult
    public mutating func complete(expected: String?) -> Bool {
        guard let first = rows.first else { return false }
        if let expected, expected != first.title { return false }
        rows.removeFirst()
        return true
    }
}
