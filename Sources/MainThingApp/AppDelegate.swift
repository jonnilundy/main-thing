import AppKit
import MainThingCore
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: MainThingBundleID, category: "app")
    private var panel: NotchPanel?
    private var store: TaskStore?
    private var server: APIServer?
    private var model: NotchModel?
    private var hover: HoverController?
    private var snapshotter: Snapshotter?
    private var reminder: Reminder?
    private var editor: EditorController?
    private var tearOff: TearOffController?
    private var screenObserver: (any NSObjectProtocol)?
    private var updater: Updater?

    /// `MAINTHING_HEADLESS=1`: no notch, no hover, no single instance check. The store and the API
    /// run as usual, so smoke tests can drive a second copy on another port while the real one shows.
    static var headless: Bool { ProcessInfo.processInfo.environment["MAINTHING_HEADLESS"] == "1" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppDelegate.headless {
            let store = TaskStore()
            let server = APIServer(store: store)
            server.start()
            self.store = store
            self.server = server
            log.notice("headless: store at \(store.fileURL.path, privacy: .public), api ports \(server.candidates.map(String.init).joined(separator: ", "), privacy: .public)")
            return
        }
        guard quitIfAnotherInstanceRuns() == false else { return }

        let updater = Updater()
        updater.start()
        self.updater = updater

        guard let geometry = currentGeometry() else {
            log.error("no screen at launch")
            return
        }

        let store = TaskStore()
        let server = APIServer(store: store)
        let model = NotchModel(geometry: geometry, apiPort: server.port)
        model.forceOpen = CommandLine.arguments.contains("--open")
        server.onStatus = { [weak model] bound, port in
            model?.apiBound = bound
            model?.apiPort = port
        }
        server.start()
        self.store = store
        self.server = server
        self.model = model

        let panel = NotchPanel(contentRect: geometry.panelFrame)
        let layout = PanelLayout(panel: panel, model: model, store: store)
        let sounds = Sounds()
        SettingsWindow.sounds = sounds
        SettingsWindow.installShortcut()
        let hover = HoverController(panel: panel, model: model, store: store, layout: layout, sounds: sounds)
        store.onChange = { [weak hover] in hover?.listChanged() }
        let reminder = Reminder(store: store, model: model)
        let editor = EditorController(store: store, model: model, notchPanel: panel, hover: hover)
        self.editor = editor
        let root = NotchView(
            store: store, model: model, sounds: sounds, reminder: reminder,
            onToggle: { [weak hover] row in hover?.toggleCompletion(of: row) },
            onEditList: { [weak editor] in editor?.openFromMenu() }
        )
        let hosting = NotchHostingView(rootView: root)
        hosting.onMouseMove = { [weak hover] point in hover?.evaluate(at: point, source: "tracking") }
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
        self.hover = hover
        hover.start()
        let tearOff = TearOffController(model: model, panel: panel, hover: hover, editor: editor)
        tearOff.start()
        self.tearOff = tearOff

        snapshotter = Snapshotter(store: store, model: model)
        snapshotter?.start()
        self.reminder = reminder
        reminder.start()
        // `MainThing --settings` opens Settings at launch, for scripts and screenshots.
        if CommandLine.arguments.contains("--settings") { SettingsWindow.show() }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }

        log.info("panel up at \(NSStringFromRect(geometry.panelFrame), privacy: .public), notch height \(geometry.notchHeight, privacy: .public), hardware notch \(geometry.hasHardwareNotch, privacy: .public), api ports \(server.candidates.map(String.init).joined(separator: ", "), privacy: .public)")
    }

    /// Geometry for the chosen screen: the one with a hardware notch, else the primary.
    private func currentGeometry() -> NotchGeometry? {
        let screens = NSScreen.screens.map(ScreenInfo.init)
        guard let index = NotchGeometry.chooseScreen(screens) else { return nil }
        return NotchGeometry(screen: screens[index])
    }

    /// Display added, removed, or changed: move the panel and relayout the notch.
    private func screensChanged() {
        guard let panel, let model, let geometry = currentGeometry() else { return }
        guard geometry != model.geometry else { return }
        panel.setFrame(geometry.panelFrame, display: true)
        model.geometry = geometry
        hover?.refresh()
        log.notice("display change: panel at \(NSStringFromRect(geometry.panelFrame), privacy: .public), notch height \(geometry.notchHeight, privacy: .public), hardware notch \(geometry.hasHardwareNotch, privacy: .public)")
    }

    /// One instance only. Returns true when this process should stop because another copy runs.
    private func quitIfAnotherInstanceRuns() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? MainThingBundleID
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let other = others.first else { return false }
        log.notice("another Main Thing runs as pid \(other.processIdentifier, privacy: .public), quitting")
        NSApp.terminate(nil)
        return true
    }
}
