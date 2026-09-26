/// Environment variables are `MAIN_THING_<NAME>`. Until 0.4 the old `MAINTHING_<NAME>` is read too
/// when the new one is not set.
public enum Env {
    public static let prefix = "MAIN_THING_"
    public static let legacyPrefix = "MAINTHING_"

    /// The value of `MAIN_THING_<name>`, else of `MAINTHING_<name>`. Empty counts as not set.
    public static func value(_ name: String, in environment: [String: String]) -> String? {
        for key in [prefix + name, legacyPrefix + name] {
            if let value = environment[key], !value.isEmpty { return value }
        }
        return nil
    }
}
