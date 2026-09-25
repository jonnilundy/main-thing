import AppKit
import NextUpCore
import ServiceManagement
import os

/// Launch at Login through `SMAppService.mainApp`. The app must run from a bundle.
@MainActor
enum LaunchAtLogin {
    private static let log = Logger(subsystem: NextUpBundleID, category: "login")

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    static var needsApproval: Bool { status == .requiresApproval }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .requiresApproval: "requires approval in System Settings > General > Login Items"
        case .notRegistered: "not registered"
        case .notFound: "not found"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }

    /// Registers or unregisters. Returns the status afterwards. Errors are logged and rethrown.
    @discardableResult
    static func setEnabled(_ enabled: Bool) throws -> SMAppService.Status {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("launch at login \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let now = status
        log.notice("launch at login now \(describe(now), privacy: .public)")
        return now
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
