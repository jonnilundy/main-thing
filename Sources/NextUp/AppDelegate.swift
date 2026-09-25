import AppKit
import NextUpCore
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: NextUpBundleID, category: "app")
    private var panel: NotchPanel?
    private var store: TaskStore?
    private var server: APIServer?
    private var model: NotchModel?
    private var hover: HoverController?
    private var snapshotter: Snapshotter?
    private var screenObserver: (any NSObjectProtocol)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard quitIfAnotherInstanceRuns() == false else { return }

        guard let geometry = currentGeometry() else {
            log.error("no screen at launch")
            return
        }

        let store = TaskStore()
        let server = APIServer(store: store)
        let model = NotchModel(geometry: geometry, apiPort: server.port)
        model.forceOpen = CommandLine.arguments.contains("--open")
        server.onStatus = { [weak model] bound in model?.apiBound = bound }
        server.start()
        self.store = store
        self.server = server
        self.model = model

        let panel = NotchPanel(contentRect: geometry.panelFrame)
        let hover = HoverController(panel: panel, model: model, store: store)
        let root = NotchView(store: store, model: model, onDone: { [weak hover] in hover?.completeCurrent() })
        let hosting = NotchHostingView(rootView: root)
        hosting.onMouseMove = { [weak hover] point in hover?.evaluate(at: point, source: "tracking") }
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
        self.hover = hover
        hover.start()

        snapshotter = Snapshotter(store: store, model: model)
        snapshotter?.start()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }

        log.info("panel up at \(NSStringFromRect(geometry.panelFrame), privacy: .public), notch height \(geometry.notchHeight, privacy: .public), hardware notch \(geometry.hasHardwareNotch, privacy: .public), api port \(server.port, privacy: .public)")
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
        let bundleID = Bundle.main.bundleIdentifier ?? NextUpBundleID
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let other = others.first else { return false }
        log.notice("another NextUp runs as pid \(other.processIdentifier, privacy: .public), quitting")
        NSApp.terminate(nil)
        return true
    }
}
