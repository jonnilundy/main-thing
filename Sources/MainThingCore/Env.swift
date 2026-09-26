/// Environment variables are `MAIN_THING_<NAME>`.
public enum Env {
    public static let prefix = "MAIN_THING_"

    /// The value of `MAIN_THING_<name>`. Empty counts as not set.
    public static func value(_ name: String, in environment: [String: String]) -> String? {
        guard let value = environment[prefix + name], !value.isEmpty else { return nil }
        return value
    }
}
