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
    /// Undo the last cross off or discard still in its 5 second window, from any app.
    static let undo = Self("undo", initial: .init(.z, modifiers: [.control, .option]))
}

/// The Shortcuts section of Settings: a recorder per action. Click one to record, the x clears it.
struct ShortcutsSection: View {
    var body: some View {
        Section("Shortcuts") {
            KeyboardShortcuts.Recorder("Show list", name: .showList)
            KeyboardShortcuts.Recorder("Add task", name: .addTask)
            KeyboardShortcuts.Recorder("Cross off main task", name: .crossOffMain)
            KeyboardShortcuts.Recorder("Undo", name: .undo)
        }
    }
}

/// The Keyboard Shortcuts submenu of the right click menu: every shortcut with its keys, for
/// reference. The global ones show the keys set in Settings and run when picked; the keys of the
/// open list are listed, greyed, since they only work in the list.
struct KeyboardShortcutsMenu: View {
    var body: some View {
        Menu("Keyboard Shortcuts") {
            Section("From any app") {
                global("Show List", .showList) { HoverController.shared?.showList() }
                global("Add Task", .addTask) { HoverController.shared?.addTask() }
                global("Cross Off Main Task", .crossOffMain) { HoverController.shared?.crossOffMain() }
                global("Undo", .undo) { HoverController.shared?.undoShortcut() }
            }
            Section("In the open list") {
                key("Move the Highlight", .downArrow)
                key("Next Row", .tab)
                key("Cross Off, or Add", .return)
                key("Rename", "e")
                key("Discard", .delete)
                key("Move Task Up", .upArrow, [.option])
                key("Move Task Down", .downArrow, [.option])
                key("New Task", "n")
                key("Undo", "z", [.command])
                key("Close", .escape)
            }
            Divider()
            Button("Edit Shortcuts…") { SettingsWindow.show(tab: .shortcuts) }
        }
    }

    private func global(_ title: String, _ name: KeyboardShortcuts.Name, action: @escaping () -> Void) -> some View {
        let shortcut = name.shortcut?.toSwiftUI
        return Button(shortcut == nil ? title + " (not set)" : title, action: action)
            .keyboardShortcut(shortcut)
    }

    private func key(_ title: String, _ key: KeyEquivalent, _ modifiers: EventModifiers = []) -> some View {
        Button(title) {}
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(true)
    }
}
