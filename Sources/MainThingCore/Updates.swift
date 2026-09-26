import Foundation

/// Rules for the Sparkle updater that do not need Sparkle: when the updater may start, and the
/// words the menu and Settings show.
public enum UpdateRules {
    /// The value Info.plist carries until the release key exists. The updater stays off with it.
    public static let placeholderKey = "REPLACE-WITH-PUBLIC-KEY"

    /// An EdDSA public key Sparkle can use: base64 for exactly 32 bytes. The placeholder, an empty
    /// value or anything else keeps the updater off, so a build without a key never shows
    /// Sparkle's "updater failed to start" alert.
    public static func hasPublicKey(_ value: String?) -> Bool {
        guard let value, value != placeholderKey,
              let data = Data(base64Encoded: value.trimmingCharacters(in: .whitespaces)) else { return false }
        return data.count == 32
    }

    /// The menu item for a found update. A downloaded one installs and relaunches at once with no
    /// window; one that is only found opens Sparkle's window, hence the ellipsis.
    public static func installTitle(version: String, ready: Bool) -> String {
        ready ? "Install Update \(version) and Relaunch" : "Install Update \(version)…"
    }

    /// "0.2.1 (3)"; the build alone when both are the same.
    public static func versionLabel(version: String, build: String) -> String {
        version == build || build.isEmpty ? version : "\(version) (\(build))"
    }

    /// The last check line in Settings.
    public static func lastCheckLabel(date: Date?, result: String, now: Date = Date()) -> String {
        guard let date else { return "Never checked" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = now.timeIntervalSince(date) < 60 ? "just now" : formatter.localizedString(for: date, relativeTo: now)
        return result.isEmpty ? "Checked \(when)" : "Checked \(when): \(result)"
    }
}
