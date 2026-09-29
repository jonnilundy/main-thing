import Foundation
import MainThingCore
import Security
import os

/// Where built-in adapter secrets live. The app uses the Keychain; previews and probes can use
/// memory.
protocol SecretStore: Sendable {
    func read(service: String, account: String) -> String?
    /// True when an item exists. Reads attributes only, never the secret.
    func exists(service: String, account: String) -> Bool
    func write(_ value: String, service: String, account: String, label: String) throws
    func remove(service: String, account: String) throws
}

struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// Generic passwords in the login keychain: service `<bundle id>.adapter.<name>`, account the
/// environment variable name (`AdapterKeys.keychainService`).
struct KeychainStore: SecretStore {
    private func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read(service: String, account: String) -> String? {
        var q = query(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func exists(service: String, account: String) -> Bool {
        var q = query(service: service, account: account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess
    }

    func write(_ value: String, service: String, account: String, label: String) throws {
        let data = Data(value.utf8)
        let q = query(service: service, account: account)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = label
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func remove(service: String, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// Secrets in memory, for previews and probes.
final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    init(_ items: [String: String] = [:]) { self.items = items }

    func read(service: String, account: String) -> String? { lock.withLock { items[service + "/" + account] } }
    func exists(service: String, account: String) -> Bool { read(service: service, account: account) != nil }
    func write(_ value: String, service: String, account: String, label: String) throws { lock.withLock { items[service + "/" + account] = value } }
    func remove(service: String, account: String) throws { _ = lock.withLock { items.removeValue(forKey: service + "/" + account) } }
}

/// The settings of the built-in adapters: Enable and plain values in UserDefaults, secrets in a
/// `SecretStore`, the scripts in the app bundle. Safe to use from any thread.
struct AdapterSettings: @unchecked Sendable {
    let defaults: UserDefaults
    let secrets: any SecretStore
    /// The Keychain service is keyed by this (`AdapterKeys.keychainService`).
    let bundleID: String?
    /// `Contents/Resources/adapters`.
    let bundledDirectory: URL
    let configDirectory: URL

    /// The app's own: standard defaults, the Keychain, the bundle's scripts.
    /// `MAIN_THING_BUILTIN_ADAPTERS_DIR` points at other scripts, for tests.
    static func live(configDirectory: URL = EventRunner.defaultConfigDirectory) -> AdapterSettings {
        let env = ProcessInfo.processInfo.environment
        let dir = Env.value("BUILTIN_ADAPTERS_DIR", in: env).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("adapters", isDirectory: true)
        return AdapterSettings(defaults: .standard, secrets: KeychainStore(), bundleID: Bundle.main.bundleIdentifier, bundledDirectory: dir, configDirectory: configDirectory)
    }

    // MARK: Enable and values

    /// Nil when never set.
    func storedEnabled(_ name: String) -> Bool? {
        defaults.object(forKey: AdapterKeys.enabled(name)) == nil ? nil : defaults.bool(forKey: AdapterKeys.enabled(name))
    }

    func isEnabled(_ name: String) -> Bool { storedEnabled(name) ?? false }

    func setEnabled(_ name: String, _ on: Bool) { defaults.set(on, forKey: AdapterKeys.enabled(name)) }

    func plainValue(_ adapter: BuiltInAdapter, _ field: AdapterField) -> String {
        defaults.string(forKey: AdapterKeys.value(adapter.name, field.envName)) ?? ""
    }

    func setPlainValue(_ value: String, _ adapter: BuiltInAdapter, _ field: AdapterField) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = AdapterKeys.value(adapter.name, field.envName)
        if trimmed.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(trimmed, forKey: key) }
    }

    func service(_ adapter: BuiltInAdapter) -> String { AdapterKeys.keychainService(bundleID: bundleID, adapter: adapter.name) }

    func hasSecret(_ adapter: BuiltInAdapter, _ field: AdapterField) -> Bool {
        secrets.exists(service: service(adapter), account: field.envName)
    }

    func setSecret(_ value: String, _ adapter: BuiltInAdapter, _ field: AdapterField) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try secrets.remove(service: service(adapter), account: field.envName)
        } else {
            try secrets.write(trimmed, service: service(adapter), account: field.envName, label: "Main Thing: \(adapter.displayName) \(field.label)")
        }
    }

    func removeSecret(_ adapter: BuiltInAdapter, _ field: AdapterField) throws {
        try secrets.remove(service: service(adapter), account: field.envName)
    }

    /// True when a field has a value here, in UserDefaults or the store.
    func hasValue(_ adapter: BuiltInAdapter, _ field: AdapterField) -> Bool {
        field.secret ? hasSecret(adapter, field) : !plainValue(adapter, field).isEmpty
    }

    func envFileExists(_ adapter: BuiltInAdapter) -> Bool {
        FileManager.default.fileExists(atPath: adapter.envFile(configDirectory: configDirectory).path)
    }

    // MARK: Running

    func bundledPath(_ name: String) -> String { bundledDirectory.appendingPathComponent(name).path }

    /// Which executable answers for each adapter name right now.
    func lookup() -> AdapterLookup {
        var enabled: [String: String] = [:]
        for adapter in BuiltInAdapters.all where isEnabled(adapter.name) {
            enabled[adapter.name] = bundledPath(adapter.name)
        }
        return AdapterLookup(enabledBuiltIns: enabled)
    }

    /// The variables one run of a built-in adapter gets. Reads the secrets, so call it right
    /// before the run and let the result go with the process. Never log it.
    func environment(for name: String) -> [String: String] {
        guard let adapter = BuiltInAdapters.named(name) else { return [:] }
        var stored: [String: String] = [:]
        for field in adapter.fields {
            let value = field.secret ? secrets.read(service: service(adapter), account: field.envName) : plainValue(adapter, field)
            if let value { stored[field.envName] = value }
        }
        return AdapterEnvironment.values(for: adapter, stored: stored, configDirectory: configDirectory)
    }

    /// The full environment for one built-in run: the usual child environment with the adapter's
    /// values on top.
    func processEnvironment(for name: String) -> [String: String] {
        let base = EventRunner.childEnvironment()
        guard let adapter = BuiltInAdapters.named(name) else { return base }
        return AdapterEnvironment.merged(base: base, adapter: adapter, values: environment(for: name))
    }

    // MARK: Migration

    /// Files in the adapters folder with a built-in's name. They never run while the built-in exists.
    func shadowedFiles() -> [String] {
        let folder = EventPlan.adaptersDirectory(configDirectory)
        return BuiltInAdapters.all.map(\.name).filter {
            let path = folder.appendingPathComponent($0).path
            return FileManager.default.fileExists(atPath: path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
        }
    }

    /// On launch: turns on each built-in whose Enable was never set when it was set up by hand
    /// before (a file in the adapters folder or an env file). Returns one line per change and per
    /// shadowed file, for the log. Deletes nothing.
    @discardableResult
    func migrate() -> [String] {
        var lines: [String] = []
        let shadowed = Set(shadowedFiles())
        for adapter in BuiltInAdapters.all {
            let decision = AdapterMigration.enable(
                stored: storedEnabled(adapter.name),
                adapterFileExists: shadowed.contains(adapter.name),
                envFileExists: envFileExists(adapter)
            )
            if let decision {
                setEnabled(adapter.name, decision)
                lines.append("\(adapter.name): turned on, it was set up by hand before")
            }
            if shadowed.contains(adapter.name) {
                lines.append("\(adapter.name): \(EventPlan.adaptersDirectory(configDirectory).appendingPathComponent(adapter.name).path) is shadowed by the built-in adapter and does not run")
            }
        }
        return lines
    }

    // MARK: Check

    /// Runs `<adapter> check` with the stored values, off the main thread.
    func check(_ name: String) async -> AdapterCheck.Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let path = bundledPath(name)
                if let problem = RunPermission.problem(EventRunner.facts(of: path), currentUID: getuid(), allowRoot: true) {
                    continuation.resume(returning: .failed("The built-in script at \(path) cannot run: \(problem)."))
                    return
                }
                let (record, stdout) = EventRunner.execute(
                    path: path, arguments: ["check"], stdin: Data(), timeout: AdapterCheck.timeout,
                    environment: processEnvironment(for: name)
                )
                continuation.resume(returning: AdapterCheck.outcome(adapter: name, record: record, stdout: stdout))
            }
        }
    }
}
