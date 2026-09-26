import Foundation

/// Where the task list and the config folder live. The release app (bundle id
/// `com.jonnilundy.mainthing`, or no bundle for `swift run`) uses the real ones. Any other bundle id
/// is a test copy and gets its own, keyed by that id, so a test never touches the real list, even
/// after Sparkle relaunches it without the environment. `MAINTHING_TASKS_FILE` and
/// `MAINTHING_CONFIG_DIR` still win over both.
public enum AppPaths {
    public static func isRelease(bundleID: String?) -> Bool {
        bundleID == nil || bundleID == MainThingBundleID
    }

    /// "MainThing" for the release app, "MainThing-<bundle id>" for a test copy.
    public static func dataFolderName(bundleID: String?) -> String {
        guard let bundleID, !isRelease(bundleID: bundleID) else { return "MainThing" }
        return "MainThing-" + bundleID
    }

    /// "mainthing" for the release app, "mainthing-<bundle id>" for a test copy.
    public static func configFolderName(bundleID: String?) -> String {
        guard let bundleID, !isRelease(bundleID: bundleID) else { return "mainthing" }
        return "mainthing-" + bundleID
    }

    /// `<Application Support>/MainThing/tasks.json`, keyed by bundle id for a test copy.
    public static func tasksFile(environment: [String: String], bundleID: String?, applicationSupport: URL) -> URL {
        if let path = environment["MAINTHING_TASKS_FILE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return applicationSupport
            .appendingPathComponent(dataFolderName(bundleID: bundleID), isDirectory: true)
            .appendingPathComponent("tasks.json")
    }

    /// `~/.config/mainthing` or `$XDG_CONFIG_HOME/mainthing`, keyed by bundle id for a test copy.
    public static func configDirectory(environment: [String: String], bundleID: String?, home: String) -> URL {
        if let path = environment["MAINTHING_CONFIG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent(configFolderName(bundleID: bundleID), isDirectory: true)
    }

    /// Only the release app copies the old NextUp list on first launch. A test copy starts empty.
    public static func copiesLegacyList(bundleID: String?) -> Bool {
        isRelease(bundleID: bundleID)
    }
}
