import AppKit
import MainThingCore
import SwiftUI
import os

/// The Settings window: General (Launch at Login, Sound, Reminder) and Updates (version, Check
/// Now, automatic checks, the last check). `SettingsWindow.show()` opens it or brings it forward;
/// Cmd comma does the same while the app is active. It takes focus, since the user opened it.
@MainActor
enum SettingsWindow {
    /// The app's sound player, for the Sound picker's preview. Set once at launch.
    static var sounds: Sounds?

    private static var window: NSWindow?
    private static var keyMonitor: Any?
    private static let log = Logger(subsystem: MainThingBundleID, category: "settings")

    static func show() {
        let window = window ?? makeWindow()
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        log.notice("settings shown")
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
        let hosting = NSHostingController(rootView: SettingsView(sounds: sounds, updater: Updater.shared))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Main Thing Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MainThingSettings")
        return window
    }
}
