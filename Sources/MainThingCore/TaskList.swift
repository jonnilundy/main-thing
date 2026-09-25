import Foundation

/// One task: a title and an optional `ref`, the same task's id in another tool as `<adapter>:<id>`.
///
/// On the wire and on disk this is `{"title":"A"}` or `{"title":"B","ref":"openbrain:md7abc"}`.
/// A bare string decodes too, so files and bodies written before refs existed still load.
public struct TaskItem: Hashable, Sendable, Codable {
    public var title: String
    public var ref: String?

    public init(_ title: String, ref: String? = nil) {
        self.title = title
        self.ref = ref
    }

    private enum CodingKeys: String, CodingKey { case title, ref }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let title = try? single.decode(String.self) {
            self.init(title)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            try container.decode(String.self, forKey: .title),
            ref: try container.decodeIfPresent(String.self, forKey: .ref)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(ref, forKey: .ref)
    }
}

extension TaskItem: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(value) }
}

/// A parsed ref: `<adapter>:<id>`. The adapter name is `[a-z0-9-]+`, the id is the rest, not empty.
public struct TaskRef: Equatable, Sendable {
    public static let maxLength = 256

    public let adapter: String
    public let id: String

    public init?(_ ref: String) {
        guard TaskRef.problem(ref) == nil, let colon = ref.firstIndex(of: ":") else { return nil }
        adapter = String(ref[..<colon])
        id = String(ref[ref.index(after: colon)...])
    }

    /// Why a ref is not acceptable, or nil when it is.
    public static func problem(_ ref: String) -> String? {
        if ref.count > maxLength { return "ref is over \(maxLength) characters" }
        guard let colon = ref.firstIndex(of: ":") else { return "ref must look like <adapter>:<id>" }
        let adapter = ref[..<colon]
        let id = ref[ref.index(after: colon)...]
        if adapter.isEmpty || !adapter.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) {
            return "ref adapter name must be [a-z0-9-]+ before the colon"
        }
        if id.isEmpty { return "ref has no id after the colon" }
        if id.contains(where: { $0.isWhitespace || $0.isNewline || ($0.asciiValue ?? 32) < 32 }) {
            return "ref id must not hold whitespace or control characters"
        }
        return nil
    }
}

/// The ordered task list. Index 0 is the current task.
///
/// In memory each task carries a stable key so SwiftUI rows keep their identity across a done
/// and across a replace that touches other tasks. A task with a ref is keyed by the ref, so a
/// rename keeps its row. A task without a ref is keyed by title plus occurrence number, so
/// duplicate titles get different keys.
public struct TaskList: Equatable, Sendable {
    public struct Row: Identifiable, Hashable, Sendable {
        public let title: String
        public let ref: String?
        public let occurrence: Int

        public init(title: String, ref: String? = nil, occurrence: Int = 0) {
            self.title = title
            self.ref = ref
            self.occurrence = occurrence
        }

        /// Stable identity: "ref:openbrain:md7abc" for a ref'd task, else "Write memo#0".
        public var key: String { ref.map { "ref:\($0)" } ?? "\(title)#\(occurrence)" }
        public var id: String { key }
        public var task: TaskItem { TaskItem(title, ref: ref) }
    }

    public private(set) var rows: [Row]

    public init(_ titles: [String] = []) {
        self.init(titles.map { TaskItem($0) })
    }

    public init(_ tasks: [TaskItem]) {
        rows = []
        replace(tasks)
    }

    public var titles: [String] { rows.map(\.title) }
    public var tasks: [TaskItem] { rows.map(\.task) }
    public var current: String? { rows.first?.title }
    public var isEmpty: Bool { rows.isEmpty }
    public var count: Int { rows.count }

    /// Trims every title and drops the blank ones. Refs are trimmed too; an empty ref becomes none.
    public static func clean(_ tasks: [TaskItem]) -> [TaskItem] {
        tasks.compactMap { task in
            let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let ref = task.ref?.trimmingCharacters(in: .whitespacesAndNewlines)
            return TaskItem(title, ref: ref.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    public static func clean(_ titles: [String]) -> [String] {
        clean(titles.map { TaskItem($0) }).map(\.title)
    }

    public mutating func replace(_ titles: [String]) {
        replace(titles.map { TaskItem($0) })
    }

    /// Replaces the whole list. A row whose ref is still present keeps its key, with the new title.
    /// A row without a ref whose title is still present keeps its key. New titles get the lowest
    /// occurrence number not in use for that title.
    public mutating func replace(_ newTasks: [TaskItem]) {
        var pool = rows
        var used: [String: Set<Int>] = [:]
        for row in pool where row.ref == nil {
            used[row.title, default: []].insert(row.occurrence)
        }
        var result: [Row] = []
        for task in TaskList.clean(newTasks) {
            if let ref = task.ref {
                if let i = pool.firstIndex(where: { $0.ref == ref }) {
                    let old = pool.remove(at: i)
                    result.append(Row(title: task.title, ref: ref, occurrence: old.occurrence))
                } else {
                    result.append(Row(title: task.title, ref: ref))
                }
            } else if let i = pool.firstIndex(where: { $0.ref == nil && $0.title == task.title }) {
                result.append(pool.remove(at: i))
            } else {
                var n = 0
                while used[task.title, default: []].contains(n) { n += 1 }
                used[task.title, default: []].insert(n)
                result.append(Row(title: task.title, occurrence: n))
            }
        }
        rows = result
    }

    /// Removes the current task. When `expected` is given, it must equal the
    /// current title, so a stale done from the UI cannot remove the wrong task.
    /// Returns the removed task, or nil when the list did not change.
    @discardableResult
    public mutating func complete(expected: String?) -> TaskItem? {
        guard let first = rows.first else { return nil }
        return complete(key: first.key, expected: expected)
    }

    /// Removes the row with `key`, anywhere in the list. When `expected` is given, it must equal
    /// that row's title. Returns the removed task, or nil when the list did not change.
    @discardableResult
    public mutating func complete(key: String, expected: String?) -> TaskItem? {
        guard let i = rows.firstIndex(where: { $0.key == key }) else { return nil }
        if let expected, expected != rows[i].title { return nil }
        return rows.remove(at: i).task
    }

    /// The row key at a 0 based index, or nil when out of range.
    public func key(at index: Int) -> String? {
        rows.indices.contains(index) ? rows[index].key : nil
    }

    /// The row key of the task with `ref`, or nil when no task has it.
    public func key(ref: String) -> String? {
        rows.first { $0.ref == ref }?.key
    }
}
