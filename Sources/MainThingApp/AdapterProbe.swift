import Foundation
import MainThingCore

/// `MainThing --probe-adapters`: the built-in adapter plumbing end to end, with fake adapter
/// scripts, a UserDefaults suite and a Keychain service of its own (keyed by a probe bundle id and
/// the pid), all removed at the end. Never touches the app's defaults, Keychain items, list or
/// config. Prints one line per check and exits 0 when all pass.
@MainActor
enum AdapterProbe {
    private static var failures = 0
    private static var passes = 0

    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passes += 1
            print("ok   \(name)")
        } else {
            failures += 1
            let more = detail()
            print("FAIL \(name)" + (more.isEmpty ? "" : ": \(more)"))
        }
    }

    /// Pumps the main run loop until `done` or the timeout.
    private static func wait(_ seconds: TimeInterval = 5, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    private static func script(_ url: URL, _ body: String) throws {
        try ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func run() -> Never {
        let fm = FileManager.default
        let pid = ProcessInfo.processInfo.processIdentifier
        let probeID = "com.jonnilundy.mainthing.probe-\(pid)"
        let root = fm.temporaryDirectory.appendingPathComponent("main-thing-adapter-probe-\(pid)", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        let defaults = UserDefaults(suiteName: probeID)!
        let keychain = KeychainStore()
        let settings = AdapterSettings(defaults: defaults, secrets: keychain, bundleID: probeID, bundledDirectory: bundled, configDirectory: config)
        let linear = BuiltInAdapters.linear
        let openBrain = BuiltInAdapters.openBrain
        let linearKey = linear.fields[0]
        let obURL = openBrain.fields[0]
        let obKey = openBrain.fields[1]

        func cleanUp() {
            for adapter in BuiltInAdapters.all {
                for field in adapter.fields where field.secret { try? settings.removeSecret(adapter, field) }
            }
            defaults.removePersistentDomain(forName: probeID)
            try? fm.removeItem(at: root)
        }

        do {
            for dir in [EventPlan.adaptersDirectory(config), EventPlan.hooksDirectory(config), bundled, out] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            // The fake built-ins note what they got. The key itself is written only to the probe's
            // own scratch folder, which is removed at the end.
            try script(bundled.appendingPathComponent("linear"), """
            case "$1" in
                complete) { echo "args $*"; echo "key ${LINEAR_API_KEY:-none}"; echo "config ${MAIN_THING_CONFIG_DIR:-none}"; } > "\(out.path)/linear-complete" ;;
                resolve) case "$2" in https://linear.app/*) printf '{"id":"%s","title":"Probe issue %s"}\\n' "${2##*/}" "${LINEAR_API_KEY:+with key}" ;; *) exit 3 ;; esac ;;
                check) [[ -n "${LINEAR_API_KEY:-}" ]] || { echo "linear: no API key" >&2; exit 1; }; echo "Signed in as Probe" ;;
                *) exit 2 ;;
            esac
            """)
            try script(bundled.appendingPathComponent("openbrain"), """
            case "$1" in
                complete) { echo "url ${OPEN_BRAIN_API_URL:-none}"; echo "key ${OPEN_BRAIN_API_KEY:-none}"; } > "\(out.path)/openbrain-complete" ;;
                check) echo "Connected to ${OPEN_BRAIN_API_URL#*://}" ;;
                *) exit 2 ;;
            esac
            """)
            // A hand installed linear in the folder, as before the built-ins: it must never run.
            try script(root.appendingPathComponent("old-linear"), "echo ran > \"\(out.path)/shadow-ran\"\n")
            try fm.createSymbolicLink(at: EventPlan.adaptersDirectory(config).appendingPathComponent("linear"), withDestinationURL: root.appendingPathComponent("old-linear"))
            // A custom adapter and a hook that notes whether it sees any adapter secret.
            try script(EventPlan.adaptersDirectory(config).appendingPathComponent("mytool"), "echo \"$*\" > \"\(out.path)/mytool\"\n")
            try script(EventPlan.hooksDirectory(config).appendingPathComponent("task-completed"),
                       "cat >/dev/null; echo \"linear ${LINEAR_API_KEY:-none} ob ${OPEN_BRAIN_API_KEY:-none}\" > \"\(out.path)/hook\"\n")
        } catch {
            print("FAIL could not set up the probe: \(error)")
            cleanUp()
            exit(1)
        }

        print("-- Keychain")
        let service = settings.service(linear)
        check("the probe's service is its own", service == probeID + ".adapter.linear" && service != AdapterKeys.keychainService(bundleID: MainThingBundleID, adapter: "linear"))
        check("no key before", !settings.hasSecret(linear, linearKey))
        let key1 = "probe-key-\(UUID().uuidString)"
        do {
            try settings.setSecret(key1, linear, linearKey)
            check("saving a key works", true)
        } catch {
            check("saving a key works", false, "\(error)")
        }
        check("it exists", settings.hasSecret(linear, linearKey))
        check("it reads back", keychain.read(service: service, account: "LINEAR_API_KEY") == key1)
        let key2 = "probe-key-\(UUID().uuidString)"
        try? settings.setSecret("  \(key2)\n", linear, linearKey)
        check("saving again replaces it, trimmed", keychain.read(service: service, account: "LINEAR_API_KEY") == key2)
        try? settings.removeSecret(linear, linearKey)
        check("remove deletes it", !settings.hasSecret(linear, linearKey) && keychain.read(service: service, account: "LINEAR_API_KEY") == nil)
        try? settings.removeSecret(linear, linearKey)
        check("removing twice is fine", !settings.hasSecret(linear, linearKey))
        try? settings.setSecret(key1, linear, linearKey)

        print("-- Migration")
        check("Enable was never set", settings.storedEnabled("linear") == nil && settings.storedEnabled("openbrain") == nil)
        check("the folder file is seen as shadowed", settings.shadowedFiles() == ["linear"])
        let lines = settings.migrate()
        check("a hand installed adapter is turned on", settings.isEnabled("linear"), lines.joined(separator: "; "))
        check("one without a file or env file stays off", settings.storedEnabled("openbrain") == nil)
        check("the shadowed file is logged", lines.contains { $0.contains("shadowed") })
        try? "OPEN_BRAIN_API_URL=https://x.test\n".write(to: openBrain.envFile(configDirectory: config), atomically: true, encoding: .utf8)
        settings.setEnabled("openbrain", false)
        settings.migrate()
        check("turned off by the user stays off, even with an env file", settings.storedEnabled("openbrain") == false)
        settings.setEnabled("openbrain", false)
        defaults.removeObject(forKey: AdapterKeys.enabled("openbrain"))
        settings.migrate()
        check("never set with an env file: turned on", settings.isEnabled("openbrain"))
        check("a second launch changes nothing", !settings.migrate().contains { $0.contains("turned on") })
        check("the user's files are all still there", fm.fileExists(atPath: EventPlan.adaptersDirectory(config).appendingPathComponent("linear").path)
              && fm.fileExists(atPath: openBrain.envFile(configDirectory: config).path))

        print("-- Running")
        settings.setPlainValue(" https://probe.test/ ", openBrain, obURL)
        try? settings.setSecret("probe-ob-key", openBrain, obKey)
        let env = settings.environment(for: "openbrain")
        check("Open Brain gets the URL and the key", env["OPEN_BRAIN_API_URL"] == "https://probe.test/" && env["OPEN_BRAIN_API_KEY"] == "probe-ob-key")
        check("and the config folder", env["MAIN_THING_CONFIG_DIR"] == config.path)
        check("the app's own environment never gets a key", ProcessInfo.processInfo.environment["LINEAR_API_KEY"] == nil && ProcessInfo.processInfo.environment["OPEN_BRAIN_API_KEY"] == nil)

        var results: [(EventJob, RunRecord)] = []
        let runner = EventRunner(configDirectory: config, adapters: settings) { job, record in
            MainActor.assumeIsolated { results.append((job, record)) }
        }
        let at = Date()
        runner.emit(EventPayload(event: .taskCompleted, source: "probe", at: at, task: TaskItem("T", ref: "linear:ENG-1"), tasks: []))
        wait { results.count >= 2 }
        let completeOut = read(out.appendingPathComponent("linear-complete"))
        check("crossing off runs the bundled linear", completeOut.contains("args complete ENG-1"), completeOut)
        check("with the key from the Keychain", completeOut.contains("key \(key1)"))
        check("and the config folder", completeOut.contains("config \(config.path)"))
        check("the shadowed folder file never ran", !fm.fileExists(atPath: out.appendingPathComponent("shadow-ran").path))
        check("the run is recorded as the linear adapter, ok", results.first.map { $0.0.id == "adapter:linear" && $0.0.builtIn && $0.1.ok } == true)
        let hook = read(out.appendingPathComponent("hook"))
        check("the hook ran and saw no adapter secret", hook.contains("linear none ob none"), hook)

        results = []
        runner.emit(EventPayload(event: .taskCompleted, source: "probe", at: at, task: TaskItem("T", ref: "openbrain:qh75pbc"), tasks: []))
        wait { results.count >= 2 }
        let obOut = read(out.appendingPathComponent("openbrain-complete"))
        check("Open Brain gets both values", obOut.contains("url https://probe.test/") && obOut.contains("key probe-ob-key"), obOut)

        results = []
        runner.emit(EventPayload(event: .taskCompleted, source: "probe", at: at, task: TaskItem("T", ref: "mytool:9"), tasks: []))
        wait { results.count >= 2 }
        check("a custom adapter runs as before", read(out.appendingPathComponent("mytool")).contains("complete 9"))

        settings.setEnabled("linear", false)
        try? fm.removeItem(at: out.appendingPathComponent("linear-complete"))
        results = []
        runner.emit(EventPayload(event: .taskCompleted, source: "probe", at: at, task: TaskItem("T", ref: "linear:ENG-2"), tasks: []))
        wait { results.count >= 1 }
        wait(0.5) { false }
        check("disabled: only the hook runs", results.map(\.0.id) == ["hook:task-completed"], results.map(\.0.id).joined(separator: ","))
        check("disabled: neither linear ran", !fm.fileExists(atPath: out.appendingPathComponent("linear-complete").path) && !fm.fileExists(atPath: out.appendingPathComponent("shadow-ran").path))
        settings.setEnabled("linear", true)

        let installed = runner.installed().adapters
        check("status lists the built-in", installed.contains { $0.name == "linear" && $0.builtIn == true && $0.problem == nil })
        check("status lists the folder file as shadowed", installed.contains { $0.name == "linear" && $0.builtIn == nil && $0.problem == EventRunner.shadowedProblem })
        check("status lists the custom adapter as allowed", installed.contains { $0.name == "mytool" && $0.problem == nil })

        print("-- Resolve")
        let resolver = LinkResolver(configDirectory: config, adapters: settings)
        var resolved: LinkResolver.Result?
        resolver.resolve("https://linear.app/acme/issue/ENG-7") { resolved = $0 }
        wait { resolved != nil }
        check("a Linear link resolves through the bundled script with the key", resolved == .resolved(title: "Probe issue with key", ref: "linear:ENG-7", adapter: "linear"), "\(String(describing: resolved))")

        print("-- Check")
        var outcome: AdapterCheck.Outcome?
        Task { outcome = await settings.check("linear") }
        wait { outcome != nil }
        check("Check with the key says who", outcome == .ok("Signed in as Probe"), "\(String(describing: outcome))")
        try? settings.removeSecret(linear, linearKey)
        outcome = nil
        Task { outcome = await settings.check("linear") }
        wait { outcome != nil }
        check("Check without a key says so in plain words", outcome == .failed("no API key"), "\(String(describing: outcome))")
        outcome = nil
        Task { outcome = await settings.check("openbrain") }
        wait { outcome != nil }
        check("Check of Open Brain", outcome == .ok("Connected to probe.test/"), "\(String(describing: outcome))")

        print("-- Settings model")
        let model = AdaptersModel(settings: settings, store: nil)
        check("the model sees Open Brain as set", model.complete(openBrain) && !model.usesEnvFile(openBrain))
        check("Linear without a key has no env file to fall back to", !model.complete(linear) && !model.usesEnvFile(linear))
        model.removeSecret(openBrain, obKey)
        check("removing the key: the env file is used", !model.complete(openBrain) && model.usesEnvFile(openBrain))
        check("saving through the model reaches the Keychain", model.saveSecret("probe-ob-2", openBrain, obKey) && keychain.read(service: settings.service(openBrain), account: "OPEN_BRAIN_API_KEY") == "probe-ob-2")

        cleanUp()
        check("clean up removed the probe's Keychain items", !settings.hasSecret(linear, linearKey) && !settings.hasSecret(openBrain, obKey))
        print(failures == 0 ? "all adapter checks passed (\(passes))" : "adapter probe: \(failures) failed, \(passes) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
