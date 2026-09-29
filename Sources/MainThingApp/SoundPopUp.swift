import AppKit
import SwiftUI

/// A pop up menu of sounds that plays each option as the pointer moves over it, so the options can
/// be heard before one is picked. A SwiftUI Picker reports no hover; the menu's delegate does.
struct SoundPopUp: NSViewRepresentable {
    enum Entry {
        case header(String)
        case option(title: String, value: String)
        case divider
    }

    let entries: [Entry]
    let selected: String
    /// Picked: store it. The sound already played on hover.
    let onSelect: (String) -> Void
    /// The pointer moved onto an option: play it once.
    let onHover: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        guard let menu = button.menu else { return }
        menu.delegate = context.coordinator
        let values = entries.map(\.key)
        if context.coordinator.built != values {
            menu.removeAllItems()
            for entry in entries {
                switch entry {
                case .header(let title):
                    menu.addItem(NSMenuItem.sectionHeader(title: title))
                case .divider:
                    menu.addItem(.separator())
                case .option(let title, let value):
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.representedObject = value
                    menu.addItem(item)
                }
            }
            context.coordinator.built = values
        }
        if let item = menu.items.first(where: { ($0.representedObject as? String) == selected }), button.selectedItem !== item {
            button.select(item)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: SoundPopUp?
        var built: [String] = []
        private var hovered: String?

        @objc func picked(_ sender: NSPopUpButton) {
            guard let value = sender.selectedItem?.representedObject as? String else { return }
            parent?.onSelect(value)
        }

        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            guard let value = item?.representedObject as? String, value != hovered else { return }
            hovered = value
            parent?.onHover(value)
        }

        func menuDidClose(_ menu: NSMenu) { hovered = nil }
    }
}

private extension SoundPopUp.Entry {
    /// What the menu is built from, to rebuild it only when the options change.
    var key: String {
        switch self {
        case .header(let title): "h:" + title
        case .option(let title, let value): "o:" + value + ":" + title
        case .divider: "-"
        }
    }
}
