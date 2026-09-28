import AppKit

/// The app shows no menu bar (LSUIElement), and a text field takes Cut, Copy, Paste, Select All and
/// Undo from the main menu's key equivalents. Without a main menu, Command V does nothing in the
/// card's New task and Rename fields, so a link cannot be pasted. This menu is never shown; it only
/// carries those key equivalents to the field that has the keyboard.
@MainActor
enum EditMenu {
    static func install(on app: NSApplication = .shared) {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        let main = NSMenu()
        main.addItem(item)
        app.mainMenu = main
    }

    /// The item Command plus `key` reaches, for the probe.
    static func item(forCommand key: String, in app: NSApplication = .shared) -> NSMenuItem? {
        app.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first {
            $0.keyEquivalent == key && $0.keyEquivalentModifierMask == [.command]
        }
    }
}
