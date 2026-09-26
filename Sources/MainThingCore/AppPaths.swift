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

    private static func configBase(environment: [String: String], home: String) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        return URL(fileURLWithPath: base, isDirectory: true)
    }
}
