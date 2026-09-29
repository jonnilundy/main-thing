import AppKit
import MainThingCore
import SwiftUI
import os

/// The Settings window, with toolbar tabs as macOS settings windows have: General (Launch at
/// Login, Sound, Link sound, Reminder), Shortcuts, Adapters (the built-in adapters and the custom
/// ones) and Updates (version, Check Now, automatic checks, the last check).
/// `SettingsWindow.show()` opens it or brings it forward; Cmd comma does the same while the app is
/// active. It takes focus, since the user opened it.
@MainActor
enum SettingsWindow {
    enum Tab: String, CaseIterable {
        case general, shortcuts, adapters, updates

        var label: String {
            switch self {
            case .general: "General"
            case .shortcuts: "Shortcuts"
            case .adapters: "Adapters"
            case .updates: "Updates"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .shortcuts: "keyboard"
            case .adapters: "puzzlepiece.extension"
            case .updates: "arrow.triangle.2.circlepath"
            }
        }
    }

    /// The app's sound player, for the Sound picker's preview. Set once at launch.
    static var sounds: Sounds?
    /// The Adapters tab's model. Set once at launch.
    static var adapters: AdaptersModel?

    private static var window: NSWindow?
    private static var tabs: SettingsTabs?
    private static var keyMonitor: Any?
    private static let log = Logger(subsystem: MainThingBundleID, category: "settings")

    static func show(tab: Tab? = nil) {
        let window = window ?? makeWindow()
        self.window = window
        if let tab, let index = Tab.allCases.firstIndex(of: tab) {
            tabs?.selectedTabViewItemIndex = index
        }
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        log.notice("settings shown")
        Updater.shared?.checkQuietly()
    }

    /// Cmd comma opens Settings whenever one of the app's windows has the keyboard.
    static func installShortcut() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers == "," else { return event }
            MainActor.assumeIsolated { SettingsWindow.show() }
            return nil
        }
    }

    private static func makeWindow() -> NSWindow {
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        for tab in Tab.allCases {
            let root: AnyView
            switch tab {
            case .general: root = AnyView(GeneralSettings(sounds: sounds))
            case .shortcuts: root = AnyView(ShortcutsSettings())
            case .adapters:
                if let adapters {
                    root = AnyView(AdaptersSettings(model: adapters))
                } else {
                    root = AnyView(Text("Adapters are off in this copy").padding().frame(width: settingsWidth))
                }
            case .updates: root = AnyView(UpdatesSettings(updater: Updater.shared))
            }
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = [.preferredContentSize]
            hosting.title = tab.label
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.label
            item.identifier = tab.rawValue
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.label)
            tabs.addTabViewItem(item)
        }
        self.tabs = tabs
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MainThingSettings")
        return window
    }
}

/// Toolbar tabs that size the window to the selected tab, keeping its top edge in place.
final class SettingsTabs: NSTabViewController {
    /// A fixed space between the tabs: the toolbar puts them edge to edge, so the hover and the
    /// selected highlights touched.
    override func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let tabs = super.toolbarDefaultItemIdentifiers(toolbar)
        return Array(tabs.flatMap { [$0, .space] }.dropLast())
    }

    override func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        super.toolbarAllowedItemIdentifiers(toolbar) + [.space]
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let controller = tabViewItem?.viewController, let window = view.window else { return }
        window.title = tabViewItem?.label ?? window.title
        fit(window, to: controller)
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard selectedTabViewItemIndex >= 0, selectedTabViewItemIndex < tabViewItems.count,
              viewController === tabViewItems[selectedTabViewItemIndex].viewController,
              let window = view.window else { return }
        fit(window, to: viewController)
    }

    private func fit(_ window: NSWindow, to controller: NSViewController) {
        let size = controller.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }
        let content = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var frame = window.frame
        guard abs(frame.height - content.height) > 0.5 || abs(frame.width - content.width) > 0.5 else { return }
        frame.origin.y += frame.height - content.height
        frame.size = content.size
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}
