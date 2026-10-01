import Foundation

/// Tasks that left the list from the card and can still come back: each cross off and each discard
/// gets its own `Discarded.seconds` window. Command Z (or the Undo shortcut) takes the newest one
/// still in its window, so undoing twice brings two tasks back, each to its old place. A cross off
/// commits only when its window ends: its task-completed event (the done hook, the adapter) goes
/// out then, never before, so an undo never has to reopen anything in another tool. Pure: the
/// store owns the clock and the timer.
public struct UndoStack: Equatable, Sendable {
    /// Oldest first. Entries are pushed as they happen, so the first one ends first.
    public private(set) var entries: [Discarded] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func push(_ entry: Discarded) {
        entries.append(entry)
    }

    /// Takes the newest entry still in its window off the stack. The caller puts its task back.
    public mutating func undo(at now: TimeInterval) -> Discarded? {
        guard let i = entries.lastIndex(where: { !$0.expired(at: now) }) else { return nil }
        return entries.remove(at: i)
    }

    /// Takes every entry whose window ended off the stack, oldest first. The caller commits the
    /// cross offs among them.
    public mutating func expire(at now: TimeInterval) -> [Discarded] {
        let gone = entries.filter { $0.expired(at: now) }
        entries.removeAll { $0.expired(at: now) }
        return gone
    }

    /// Everything, oldest first, and the stack is empty: the app quits, so every window ends now.
    public mutating func drain() -> [Discarded] {
        defer { entries = [] }
        return entries
    }

    /// When the next window ends, or nil when there is none.
    public var nextExpiry: TimeInterval? {
        entries.map { $0.at + Discarded.seconds }.min()
    }
}

extension EventPlan {
    /// The event a held entry sends when its window ends: `task-completed` for a cross off, with
    /// the list as it is then. A discard sends nothing. The `list-changed` went out when the row left.
    public static func commit(_ entry: Discarded, list: TaskList, source: String, at: Date) -> EventPayload? {
        guard entry.kind == .done else { return nil }
        return EventPayload(event: .taskCompleted, source: source, at: at, task: entry.task, tasks: list.tasks)
    }
}
