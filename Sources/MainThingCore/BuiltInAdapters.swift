import Foundation

/// One value a built-in adapter needs, passed to its process as an environment variable.
/// A secret lives in the Keychain, anything else in UserDefaults.
public struct AdapterField: Equatable, Sendable, Identifiable {
    /// The environment variable the script reads, for example `LINEAR_API_KEY`. Also the Keychain
    /// account for a secret.
    public var envName: String
    public var label: String
    public var secret: Bool
    public var placeholder: String
    /// One short line under the field.
    public var help: String
    /// Where to get the value.
    public var linkTitle: String
    public var link: URL

    public var id: String { envName }

    public init(envName: String, label: String, secret: Bool, placeholder: String, help: String, linkTitle: String, link: URL) {
        self.envName = envName
        self.label = label
        self.secret = secret
        self.placeholder = placeholder
        self.help = help
        self.linkTitle = linkTitle
        self.link = link
    }
}

/// An adapter that ships inside the app, at `Contents/Resources/adapters/<name>`.
public struct BuiltInAdapter: Equatable, Sendable, Identifiable {
    /// The ref prefix and the script's file name, `[a-z0-9-]+`.
    public var name: String
    public var displayName: String
    /// One line on what it does.
    public var summary: String
    public var fields: [AdapterField]

    public var id: String { name }

    public init(name: String, displayName: String, summary: String, fields: [AdapterField]) {
        self.name = name
        self.displayName = displayName
        self.summary = summary
        self.fields = fields
    }

    /// The env file the script falls back to when the app passes no values:
    /// `<config>/<name>.env`.
    public func envFile(configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent(name + ".env")
    }
}

public enum BuiltInAdapters {
    public static let linear = BuiltInAdapter(
        name: "linear",
        displayName: "Linear",
        summary: "Paste a Linear issue link to get its title. Crossing it off moves the issue to Done.",
        fields: [
            AdapterField(
                envName: "LINEAR_API_KEY", label: "API key", secret: true, placeholder: "lin_api_…",
                help: "A personal API key. In Linear: Settings, Security & access, Personal API keys.",
                linkTitle: "Open Linear security settings",
                link: URL(string: "https://linear.app/settings/account/security")!
            ),
        ]
    )

    public static let openBrain = BuiltInAdapter(
        name: "openbrain",
        displayName: "Open Brain",
        summary: "Crossing off a task with an openbrain: ref marks it done in Open Brain.",
        fields: [
            AdapterField(
                envName: "OPEN_BRAIN_API_URL", label: "API URL", secret: false, placeholder: "https://your-deployment.convex.site",
                help: "Your Open Brain deployment, the address the ob command uses.",
                linkTitle: "Open Brain setup",
                link: URL(string: "https://github.com/cpenned/open-brain#readme")!
            ),
            AdapterField(
                envName: "OPEN_BRAIN_API_KEY", label: "API key", secret: true, placeholder: "obr_…",
                help: "A key with tasks:read and tasks:write. In Open Brain: Settings, API Keys, New API key.",
                linkTitle: "How to make a key",
                link: URL(string: "https://github.com/cpenned/open-brain#step-8---mint-an-api-key-for-the-cli--mcp")!
            ),
        ]
    )

    /// In the order Settings shows them.
    public static let all: [BuiltInAdapter] = [linear, openBrain]

    public static func named(_ name: String) -> BuiltInAdapter? {
        all.first { $0.name == name }
    }

    public static var names: Set<String> { Set(all.map(\.name)) }
}

/// UserDefaults keys and Keychain names for built-in adapters. The Keychain service is keyed by
/// the bundle id, so a test copy never reads or writes the release app's items.
public enum AdapterKeys {
    /// `adapters.<name>.enabled`. Missing means never set, which the migration looks at.
    public static func enabled(_ adapter: String) -> String { "adapters.\(adapter).enabled" }

    /// `adapters.<name>.<ENV>` for a field that is not a secret.
    public static func value(_ adapter: String, _ envName: String) -> String { "adapters.\(adapter).\(envName)" }

    /// `<bundle id>.adapter.<name>`, with the release id when there is no bundle (`swift run`).
    public static func keychainService(bundleID: String?, adapter: String) -> String {
        (bundleID ?? MainThingBundleID) + ".adapter." + adapter
    }
}

/// On launch: a built-in adapter whose Enable was never set is turned on when the user had set it
/// up by hand before, with a file in the adapters folder or an env file. Nothing else migrates.
public enum AdapterMigration {
    /// The value to store, or nil to leave Enable as it is.
    public static func enable(stored: Bool?, adapterFileExists: Bool, envFileExists: Bool) -> Bool? {
        guard stored == nil else { return nil }
        return adapterFileExists || envFileExists ? true : nil
    }
}

/// Which executable answers for an adapter name. A built-in name always means the bundled script,
/// and only while it is enabled; a file with that name in the adapters folder is shadowed and
/// never runs. Any other name is a file in the adapters folder, as before.
public struct AdapterLookup: Equatable, Sendable {
    /// Enabled built-ins and the path of their bundled script.
    public var enabledBuiltIns: [String: String]
    /// Every built-in name, enabled or not.
    public var reserved: Set<String>

    public init(enabledBuiltIns: [String: String] = [:], reserved: Set<String> = BuiltInAdapters.names) {
        self.enabledBuiltIns = enabledBuiltIns
        self.reserved = reserved
    }

    /// No built-ins at all: every name is a file in the folder. Previews and old tests.
    public static let folderOnly = AdapterLookup(enabledBuiltIns: [:], reserved: [])

    public enum Source: Equatable, Sendable {
        case builtIn(path: String)
        case folder(path: String)
    }

    /// Where `name` runs from, or nil when nothing runs for it. `exists` answers for a folder path.
    public func source(for name: String, configDirectory: URL, exists: (String) -> Bool) -> Source? {
        if reserved.contains(name) {
            return enabledBuiltIns[name].map { .builtIn(path: $0) }
        }
        let path = EventPlan.adaptersDirectory(configDirectory).appendingPathComponent(name).path
        return exists(path) ? .folder(path: path) : nil
    }

    /// The names a link is offered to, in name order: valid names in the folder that are not
    /// built-in, and the enabled built-ins.
    public func resolveNames(folderNames: [String]) -> [String] {
        let custom = folderNames.filter { AdapterLookup.isValidName($0) && !reserved.contains($0) }
        return Array(Set(custom).union(enabledBuiltIns.keys)).sorted()
    }

    /// `[a-z0-9-]+`.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }
}

/// What the app passes to one built-in adapter process: the values that are set, and the config
/// folder so the script finds its env file next to the app's own config.
public enum AdapterEnvironment {
    public static func values(for adapter: BuiltInAdapter, stored: [String: String], configDirectory: URL) -> [String: String] {
        var env: [String: String] = ["MAIN_THING_CONFIG_DIR": configDirectory.path]
        for field in adapter.fields {
            if let value = stored[field.envName]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                env[field.envName] = value
            }
        }
        return env
    }

    /// The base environment with the adapter's values on top. A variable the adapter reads but
    /// the app has no value for is removed, so a value from the app's own launch environment
    /// never stands in for a missing setting and the env file fallback stays predictable.
    public static func merged(base: [String: String], adapter: BuiltInAdapter, values: [String: String]) -> [String: String] {
        var env = base
        for field in adapter.fields { env[field.envName] = nil }
        for (key, value) in values { env[key] = value }
        return env
    }
}

/// How Settings says what a `check` run returned, in plain words.
public enum AdapterCheck {
    public enum Outcome: Equatable, Sendable {
        case ok(String)
        case failed(String)
    }

    /// A check gets as long as a completion.
    public static let timeout: TimeInterval = 10

    public static func outcome(adapter: String, record: RunRecord, stdout: Data) -> Outcome {
        let out = firstLine(String(decoding: stdout, as: UTF8.self), adapter: adapter)
        if record.timedOut { return .failed("No answer in \(Int(timeout)) seconds.") }
        switch record.exit {
        case 0?:
            return .ok(out.isEmpty ? "OK" : out)
        case 2?:
            return .failed("This adapter has no check.")
        case nil:
            return .failed(record.stderr.isEmpty ? "The adapter did not run." : firstLine(record.stderr, adapter: adapter))
        case let code?:
            let why = firstLine(record.stderr, adapter: adapter)
            return .failed(why.isEmpty ? "Failed with exit \(code)." : why)
        }
    }

    /// The first non-empty line, without the `<adapter>: ` prefix the scripts put on errors.
    public static func firstLine(_ text: String, adapter: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let prefix = adapter + ": "
        return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line
    }
}
