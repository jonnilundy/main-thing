import KeyboardShortcuts
import SwiftUI

/// The global shortcuts. They work from any app: Carbon hot keys through KeyboardShortcuts, so
/// no Accessibility permission. Each is stored in UserDefaults under `KeyboardShortcuts_<name>`;
/// the initial one is written once, so a shortcut the user cleared stays cleared.
extension KeyboardShortcuts.Name {
    /// Open the card and keep it open until the pointer has been on it and left, this shortcut
    /// again, or Escape.
    static let showList = Self("showList", initial: .init(.space, modifiers: [.control, .option]))
    /// Open the card with the New task field taking the keyboard.
    static let addTask = Self("addTask", initial: .init(.n, modifiers: [.control, .option]))
    /// Cross off task 1, as a click does. No initial shortcut: it changes the list.
    static let crossOffMain = Self("crossOffMain")
}

/// The Shortcuts section of Settings: a recorder per action. Click one to record, the x clears it.
struct ShortcutsSection: View {
    var body: some View {
        Section("Shortcuts") {
            KeyboardShortcuts.Recorder("Show list", name: .showList)
            KeyboardShortcuts.Recorder("Add task", name: .addTask)
            KeyboardShortcuts.Recorder("Cross off main task", name: .crossOffMain)
        }
    }
}
