import AppKit
import MainThingCore
import Observation
import Sparkle
import os

/// What the updater knows right now. Background checks only change this; they never show a
/// window or activate the app. The right click menu (`UpdateMenuItems`) and Settings read it.
@Observable
@MainActor
final class UpdateState {
    struct Available: Equatable {
        /// The display version, "0.2.1".
        var version: String
        /// CFBundleVersion of the update, "3".
        var build: String
        var releaseNotesURL: URL?
        /// Downloaded and extracted: installing needs no window, the app relaunches at once.
        var ready: Bool
    }

    nonisolated static let resultKey = "updateLastResult"

    /// Nil when there is nothing to install.
    var available: Available? {
        didSet { if available != oldValue { log() } }
    }
    /// False when this build has no public key, or Sparkle could not start.
    var running = false
    var checking = false
    var lastCheck: Date?
    /// "Up to date", "Found 0.2.1", "Failed: ...". Kept across relaunches.
    var lastResult: String = UserDefaults.standard.string(forKey: UpdateState.resultKey) ?? "" {
        didSet { UserDefaults.standard.set(lastResult, forKey: UpdateState.resultKey) }
    }

    @ObservationIgnored private let logger = Logger(subsystem: MainThingBundleID, category: "updater")

    private func log() {
        if let available {
            logger.notice("update state: available \(available.version, privacy: .public) build \(available.build, privacy: .public) ready \(available.ready, privacy: .public) notes \(available.releaseNotesURL?.absoluteString ?? "none", privacy: .public)")
        } else {
            logger.notice("update state: none available")
        }
    }
}

/// Sparkle 2 with the standard user driver and gentle scheduled reminders.
///
/// - Scheduled checks (every 24 hours, `SUScheduledCheckInterval`) never show Sparkle's alert:
///   `standardUserDriverShouldHandleShowingScheduledUpdate` returns false, and the found update
///   only lands in `state`. With automatic downloads on (`SUAutomaticallyUpdate`), Sparkle fetches
///   and extracts it silently and hands over an install block; `installUpdate()` runs it, and the
///   app relaunches on the new version with no window. Unused, it installs when the app quits.
/// - A user initiated check (`checkForUpdates()`, Settings' Check Now, `--check-for-updates`)
///   shows Sparkle's standard window, since the user asked for it.
/// - A build whose `SUPublicEDKey` is still the placeholder never starts the updater.
@MainActor
final class Updater: NSObject {
    /// The running app's updater, for the menu items and Settings. Nil in headless copies.
    private(set) static var shared: Updater?

    let state = UpdateState()
    private let log = Logger(subsystem: MainThingBundleID, category: "updater")
    private var controller: SPUStandardUpdaterController!
    /// From `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`: installs the
    /// downloaded update and relaunches without any UI.
    private var installNow: (() -> Void)?
    private var testObservers: [any NSObjectProtocol] = []
    private var focusObservers: [any NSObjectProtocol] = []

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    var updater: SPUUpdater { controller.updater }

    /// The bundle's own version, "0.1.0", and build, "1".
    static var bundleVersion: (version: String, build: String) {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String ?? MainThingVersion,
                info["CFBundleVersion"] as? String ?? String(MainThingBuild))
    }

    func start() {
        Updater.shared = self
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard UpdateRules.hasPublicKey(key) else {
            log.notice("updates off: SUPublicEDKey is not a real key in this build")
            state.lastResult = "Off: this build has no update key"
            return
        }
        do {
            // Not the controller's startUpdater(): on an error that one shows a modal alert.
            try updater.start()
        } catch {
            log.error("sparkle did not start: \(error.localizedDescription, privacy: .public)")
            state.lastResult = "Off: \(error.localizedDescription)"
            return
        }
        state.running = true
        state.lastCheck = updater.lastUpdateCheckDate
        logFocusChanges()
        let (version, build) = Updater.bundleVersion
        log.notice("sparkle up for \(version, privacy: .public) build \(build, privacy: .public), feed \(self.updater.feedURL?.absoluteString ?? "none", privacy: .public), automatic checks \(self.updater.automaticallyChecksForUpdates, privacy: .public) every \(Int(self.updater.updateCheckInterval), privacy: .public)s, automatic downloads \(self.updater.automaticallyDownloadsUpdates, privacy: .public), last check \(self.updater.lastUpdateCheckDate?.description ?? "never", privacy: .public)")

        if CommandLine.arguments.contains("--check-for-updates") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.checkForUpdates()
            }
        }
        listenForTestInstall()
    }

    // MARK: Actions for the menu and Settings

    var canCheck: Bool { state.running && updater.canCheckForUpdates }

    /// Check for Updates… and Check Now. Sparkle's window shows the result.
    func checkForUpdates() {
        guard state.running else { return }
        log.notice("user initiated update check")
        state.checking = true
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// Install Update… from the menu. A downloaded update installs and relaunches now; one that is
    /// only found comes up in Sparkle's window for the user to confirm.
    func installUpdate() {
        guard state.running else { return }
        if let installNow {
            log.notice("installing \(self.state.available?.version ?? "?", privacy: .public) now, relaunch follows")
            state.lastResult = "Installing \(state.available?.version ?? "update")"
            installNow()
        } else {
            log.notice("showing the found update in Sparkle's window")
            NSApp.activate()
            controller.checkForUpdates(nil)
        }
    }

    var automaticallyChecks: Bool {
        get { state.running && updater.automaticallyChecksForUpdates }
        set {
            guard state.running else { return }
            updater.automaticallyChecksForUpdates = newValue
            log.notice("automatic update checks \(newValue ? "on" : "off", privacy: .public)")
        }
    }

    /// Test copies only (any bundle id but the release one), never the release app:
    /// - `<bundle id>.install-update` runs `installUpdate()`, the menu item's code path, so an end
    ///   to end test installs without clicking.
    /// - `<bundle id>.snapshot-windows` draws every visible window, title bar included, into PNGs in
    ///   `$TMPDIR/mainthing-windows/`. AppKit draws them in process, so it works on a locked screen.
    private func listenForTestInstall() {
        guard let id = Bundle.main.bundleIdentifier, !AppPaths.isRelease(bundleID: id) else { return }
        let center = DistributedNotificationCenter.default()
        let install = Notification.Name(id + ".install-update")
        testObservers.append(center.addObserver(forName: install, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log.notice("test hook: install-update received")
                self?.installUpdate()
            }
        })
        let snapshot = Notification.Name(id + ".snapshot-windows")
        testObservers.append(center.addObserver(forName: snapshot, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapshotWindows() }
        })
        log.notice("test hook: listening for \(install.rawValue, privacy: .public) and \(snapshot.rawValue, privacy: .public)")
    }

    private func snapshotWindows() {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mainthing-windows", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, window) in NSApp.windows.enumerated() where window.isVisible && !window.title.isEmpty {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = "\(index)-\(window.title.replacingOccurrences(of: " ", with: "-")).png"
            let url = folder.appendingPathComponent(name)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            log.notice("test hook: drew window '\(window.title, privacy: .public)' to \(url.path, privacy: .public)")
        }
    }

    /// The app taking focus, or any window becoming key, goes to the log: `mainthing logs` shows
    /// whether an update ever took focus without being asked to.
    private func logFocusChanges() {
        let center = NotificationCenter.default
        focusObservers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.log.notice("focus: app became active") }
        })
        focusObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                let title = NSApp.keyWindow?.title ?? "?"
                self?.log.notice("focus: window '\(title, privacy: .public)' became key")
            }
        })
    }

    private func found(_ item: SUAppcastItem, ready: Bool) {
        state.available = UpdateState.Available(
            version: item.displayVersionString,
            build: item.versionString,
            releaseNotesURL: item.releaseNotesURL ?? item.fullReleaseNotesURL ?? item.infoURL,
            ready: ready
        )
    }
}

extension Updater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log.notice("found \(item.displayVersionString, privacy: .public) build \(item.versionString, privacy: .public)")
        found(item, ready: installNow != nil && state.available?.build == item.versionString)
        state.lastResult = "Found \(item.displayVersionString)"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        log.notice("no update: \((error as NSError).localizedDescription, privacy: .public)")
        if installNow == nil { state.available = nil }
        state.lastResult = "Up to date"
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        log.notice("\(item.displayVersionString, privacy: .public) downloaded and ready, installs on quit or from the menu")
        installNow = immediateInstallHandler
        found(item, ready: true)
        state.lastResult = "Ready to install \(item.displayVersionString)"
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let error = error as NSError
        guard error.code != Int(SUError.noUpdateError.rawValue) else { return }
        log.error("update aborted: \(error.localizedDescription, privacy: .public) (\(error.code, privacy: .public))")
        state.lastResult = "Failed: \(error.localizedDescription)"
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        state.checking = false
        state.lastCheck = updater.lastUpdateCheckDate
        log.notice("update cycle done (\(updateCheck == .updates ? "user" : "background", privacy: .public)), last check \(updater.lastUpdateCheckDate?.description ?? "never", privacy: .public)")
    }

    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        log.notice("next scheduled update check in \(Int(delay), privacy: .public)s")
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        log.notice("user chose \(choice.rawValue, privacy: .public) for \(updateItem.displayVersionString, privacy: .public)")
        if choice == .skip { self.state.available = nil }
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        log.notice("relaunching into the new version")
    }
}

extension Updater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Scheduled updates are ours to show, and we show them only in the menu.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        log.notice("gentle reminder: \(update.displayVersionString, privacy: .public) (stage \(state.stage.rawValue, privacy: .public)), no window")
        found(update, ready: installNow != nil)
        self.state.lastResult = "Found \(update.displayVersionString)"
    }

    func standardUserDriverWillFinishUpdateSession() {
        // Dismissed or skipped in Sparkle's window: drop the reminder unless a download waits.
        if installNow == nil { state.available = nil }
        state.checking = false
    }
}
