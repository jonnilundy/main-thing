/// The app was called NextUp before it was Main Thing. Its list lived in
/// `~/Library/Application Support/NextUp/tasks.json`. On first launch the new app
/// copies that file when it has none of its own. The old file is left in place.
public enum LegacyData {
    /// Folder name of the old app under Application Support.
    public static let legacyDirectoryName = "NextUp"

    /// Copy only when the new file is missing and the old one exists.
    public static func shouldCopy(newExists: Bool, legacyExists: Bool) -> Bool {
        !newExists && legacyExists
    }
}
