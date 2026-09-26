import Foundation

/// Where the task list and the config folder live. The release app (bundle id
/// `com.jonnilundy.mainthing`, or no bundle for `swift run`) uses the real ones. Any other bundle id
/// is a test copy and gets its own, keyed by that id, so a test never touches the real list, even
/// after Sparkle relaunches it without the environment. `MAIN_THING_TASKS_FILE` and
/// `MAIN_THING_CONFIG_DIR` still win over both.
public enum AppPaths {
    public static func isRelease(bundleID: String?) -> Bool {
        bundleID == nil || bundleID == MainThingBundleID
    }

    /// "MainThing" for the release app, "MainThing-<bundle id>" for a test copy.
    public static func dataFolderName(bundleID: String?) -> String {
        guard let bundleID, !isRelease(bundleID: bundleID) else { return "MainThing" }
        return "MainThing-" + bundleID
    }

    /// "main-thing" for the release app, "main-thing-<bundle id>" for a test copy.
    public static func configFolderName(bundleID: String?) -> String {
        guard let bundleID, !isRelease(bundleID: bundleID) else { return "main-thing" }
        return "main-thing-" + bundleID
    }

    /// The release config folder's name before 0.3.
    public static let legacyConfigFolderName = "mainthing"

    /// `<Application Support>/MainThing/tasks.json`, keyed by bundle id for a test copy.
    public static func tasksFile(environment: [String: String], bundleID: String?, applicationSupport: URL) -> URL {
        if let path = Env.value("TASKS_FILE", in: environment) {
            return URL(fileURLWithPath: path)
        }
        return applicationSupport
            .appendingPathComponent(dataFolderName(bundleID: bundleID), isDirectory: true)
            .appendingPathComponent("tasks.json")
    }

    /// `~/.config/main-thing` or `$XDG_CONFIG_HOME/main-thing`, keyed by bundle id for a test copy.
    public static func configDirectory(environment: [String: String], bundleID: String?, home: String) -> URL {
        if let path = Env.value("CONFIG_DIR", in: environment) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return configBase(environment: environment, home: home)
            .appendingPathComponent(configFolderName(bundleID: bundleID), isDirectory: true)
    }

    /// Where the release app's config folder was before 0.3, `~/.config/mainthing`, when the app
    /// should move it to the new one on launch. Nil for a test copy, and when `MAIN_THING_CONFIG_DIR`
    /// points somewhere else.
    public static func legacyConfigDirectory(environment: [String: String], bundleID: String?, home: String) -> URL? {
        guard isRelease(bundleID: bundleID), Env.value("CONFIG_DIR", in: environment) == nil else { return nil }
        return configBase(environment: environment, home: home)
            .appendingPathComponent(legacyConfigFolderName, isDirectory: true)
    }

    /// Move the old config folder to the new one, and leave a link at the old path, only when the
    /// old one is a real folder and the new one is not there yet. A link at the old path means the
    /// move already happened; a new folder means someone set it up by hand, so both stay.
    public static func movesLegacyConfig(legacyIsFolder: Bool, legacyIsLink: Bool, newExists: Bool) -> Bool {
        legacyIsFolder && !legacyIsLink && !newExists
    }

    private static func configBase(environment: [String: String], home: String) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        return URL(fileURLWithPath: base, isDirectory: true)
    }

    /// Only the release app copies the old NextUp list on first launch. A test copy starts empty.
    public static func copiesLegacyList(bundleID: String?) -> Bool {
        isRelease(bundleID: bundleID)
    }
}
