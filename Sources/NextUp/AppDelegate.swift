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
    private var snapshotter: Snapshotter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard quitIfAnotherInstanceRuns() == false else { return }

        guard let screen = NSScreen.screens.first else {
            log.error("no screen at launch")
            return
        }

        let store = TaskStore()
        let server = APIServer(store: store)
        server.start()
        self.store = store
        self.server = server

        let geometry = NotchGeometry(screen: screen)
        let panel = NotchPanel(contentRect: geometry.panelFrame)
        let root = NotchView(store: store, notchHeight: geometry.notchHeight)
        panel.contentView = NSHostingView(rootView: root)
        panel.orderFrontRegardless()
        self.panel = panel

        snapshotter = Snapshotter(store: store, notchHeight: geometry.notchHeight)
        snapshotter?.start()

        log.info("panel up at \(NSStringFromRect(geometry.panelFrame), privacy: .public), notch height \(geometry.notchHeight, privacy: .public), api port \(server.port, privacy: .public)")
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

/// Where the panel and the notch sit on a screen.
struct NotchGeometry {
    /// Fixed panel size. The notch draws at the top center of it. Later steps open down into the rest.
    static let panelSize = CGSize(width: 800, height: 240)

    let panelFrame: NSRect
    let notchHeight: CGFloat

    @MainActor
    init(screen: NSScreen) {
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        notchHeight = menuBar > 0 ? menuBar : 30
        let size = NotchGeometry.panelSize
        panelFrame = NSRect(
            x: (screen.frame.midX - size.width / 2).rounded(),
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
