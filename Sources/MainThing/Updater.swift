import AppKit
import MainThingCore
import Sparkle
import os

/// Sparkle 2 wrapper. `SPUStandardUpdaterController` owns the updater and the standard
/// update windows. `SUFeedURL` and `SUPublicEDKey` in Info.plist tell it where to look
/// and which EdDSA key signed the archives.
///
/// `MainThing --check-for-updates` starts the app and runs a user initiated check
/// (the same as a Check for Updates menu item), for scripts and the spike.
@MainActor
final class Updater {
    private let log = Logger(subsystem: MainThingBundleID, category: "updater")
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func start() {
        controller.startUpdater()
        let updater = controller.updater
        log.notice("sparkle \(Bundle(for: SPUUpdater.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "?", privacy: .public) up, feed \(updater.feedURL?.absoluteString ?? "none", privacy: .public), automatic checks \(updater.automaticallyChecksForUpdates, privacy: .public)")
        if CommandLine.arguments.contains("--check-for-updates") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [controller] in
                controller.checkForUpdates(nil)
            }
        }
    }
}
