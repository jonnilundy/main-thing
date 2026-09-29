import Foundation

/// What a key does in the open card while the card has the keyboard (Show list or Add task) and
/// no field is open. A field takes its own keys: Return saves or adds, Escape closes it.
public enum CardKey: Equatable, Sendable {
    /// Up or Down: the highlight moves one slot, and stops at either end.
    case step(Int)
    /// Tab or Shift Tab: the highlight moves one slot, and wraps around.
    case cycle(Int)
    /// Return: cross off the highlighted task, or open New task.
    case activate
    /// E: rename the highlighted task in place.
    case rename
    /// Delete or Backspace: discard the highlighted task.
    case discard
    /// Option Up or Option Down: the highlighted task moves one place.
    case moveTask(Int)
    /// N: New task.
    case newTask
    /// Command Z: the last cross off or discard still in its window comes back.
    case undo
    /// Escape: close the card and give the keyboard back.
    case escape
}

/// The modifier keys a card key looks at. The app maps NSEvent's flags to these.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
}

/// The card's key map and the keyboard highlight. Pure; the app hands in the key and acts on it.
public enum CardKeys {
    /// Virtual key codes (the same on every keyboard layout) for the keys that are not letters.
    public enum Code {
        public static let returnKey: UInt16 = 36
        public static let keypadEnter: UInt16 = 76
        public static let tab: UInt16 = 48
        public static let delete: UInt16 = 51
        public static let forwardDelete: UInt16 = 117
        public static let escape: UInt16 = 53
        public static let up: UInt16 = 126
        public static let down: UInt16 = 125
    }

    /// The card key for a key press, or nil when the card does not use it (it goes on as usual).
    /// Letters go by the character they type, so E, N and Z follow the keyboard layout.
    public static func action(keyCode: UInt16, characters: String?, modifiers: KeyModifiers) -> CardKey? {
        if modifiers.contains(.control) { return nil }
        let plain = modifiers.subtracting(.shift).isEmpty
        switch keyCode {
        case Code.up, Code.down:
            let direction = keyCode == Code.up ? -1 : 1
            if modifiers == .option { return .moveTask(direction) }
            return modifiers.isEmpty ? .step(direction) : nil
        case Code.tab:
            guard plain, !modifiers.contains(.option) else { return nil }
            return .cycle(modifiers.contains(.shift) ? -1 : 1)
        case Code.returnKey, Code.keypadEnter:
            return modifiers.isEmpty ? .activate : nil
        case Code.delete, Code.forwardDelete:
            return modifiers.isEmpty || modifiers == .command ? .discard : nil
        case Code.escape:
            return modifiers.isEmpty ? .escape : nil
        default:
            break
        }
        switch characters?.lowercased() {
        case "e": return modifiers.isEmpty ? .rename : nil
        case "n": return modifiers.isEmpty ? .newTask : nil
        case "z": return modifiers == .command ? .undo : nil
        default: return nil
        }
    }

    /// The slots the keyboard steps through, top to bottom: every task, then New task. The Undo
    /// row is left out; Command Z reaches it.
    public static func slots(taskCount: Int) -> [CardSlot] {
        (0..<max(taskCount, 0)).map(CardSlot.task) + [.add]
    }

    /// The highlight after a step of `by` from `from`. From no highlight (or the Undo row), down
    /// goes to the first slot and up to the last. `wraps`: past either end goes round to the other.
    public static func step(from: CardSlot, by: Int, taskCount: Int, wraps: Bool) -> CardSlot {
        let slots = slots(taskCount: taskCount)
        guard let index = slots.firstIndex(of: from) else {
            return by < 0 ? slots[slots.count - 1] : slots[0]
        }
        let next = index + by
        if wraps {
            let count = slots.count
            return slots[((next % count) + count) % count]
        }
        return slots[min(max(next, 0), slots.count - 1)]
    }

    /// A keyboard highlight after the list changed: a task past the end moves to the last task,
    /// or to New task when no task is left. Anything else stays.
    public static func clamp(_ slot: CardSlot, taskCount: Int) -> CardSlot {
        guard case .task(let index) = slot, index >= taskCount else { return slot }
        return taskCount > 0 ? .task(taskCount - 1) : .add
    }
}
