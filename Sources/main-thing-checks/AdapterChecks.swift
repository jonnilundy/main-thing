import Foundation
import MainThingCore

@MainActor
func runAdapterChecks() {
    section("BuiltInAdapters")
    check("two built-ins, Linear first", BuiltInAdapters.all.map(\.name) == ["linear", "openbrain"])
    check("names are valid adapter names", BuiltInAdapters.all.allSatisfy { AdapterLookup.isValidName($0.name) })
    check("named finds one", BuiltInAdapters.named("openbrain")?.displayName == "Open Brain")
    check("named is nil for others", BuiltInAdapters.named("things") == nil)
    check("Linear needs one secret, the API key", BuiltInAdapters.linear.fields.map(\.envName) == ["LINEAR_API_KEY"] && BuiltInAdapters.linear.fields[0].secret)
    check("Open Brain: URL plain, key secret", BuiltInAdapters.openBrain.fields.map { "\($0.envName):\($0.secret)" } == ["OPEN_BRAIN_API_URL:false", "OPEN_BRAIN_API_KEY:true"])
    check("every field has help and an https link", BuiltInAdapters.all.flatMap(\.fields).allSatisfy { !$0.help.isEmpty && $0.link.scheme == "https" && !$0.linkTitle.isEmpty })
    check("env names are unique", Set(BuiltInAdapters.all.flatMap(\.fields).map(\.envName)).count == BuiltInAdapters.all.flatMap(\.fields).count)
    let config = URL(fileURLWithPath: "/Users/me/.config/main-thing", isDirectory: true)
    check("env file next to the config", BuiltInAdapters.linear.envFile(configDirectory: config).path == "/Users/me/.config/main-thing/linear.env")

    section("AdapterKeys")
    check("enabled key", AdapterKeys.enabled("linear") == "adapters.linear.enabled")
    check("value key", AdapterKeys.value("openbrain", "OPEN_BRAIN_API_URL") == "adapters.openbrain.OPEN_BRAIN_API_URL")
    check("release Keychain service", AdapterKeys.keychainService(bundleID: MainThingBundleID, adapter: "linear") == "com.jonnilundy.mainthing.adapter.linear")
    check("swift run uses the release service", AdapterKeys.keychainService(bundleID: nil, adapter: "linear") == "com.jonnilundy.mainthing.adapter.linear")
    let testService = AdapterKeys.keychainService(bundleID: "com.jonnilundy.mainthing.test", adapter: "linear")
    check("a test bundle id gets its own service", testService == "com.jonnilundy.mainthing.test.adapter.linear")
    check("a test service never is the release service", testService != AdapterKeys.keychainService(bundleID: MainThingBundleID, adapter: "linear"))
    check("each adapter its own service", AdapterKeys.keychainService(bundleID: nil, adapter: "openbrain") != AdapterKeys.keychainService(bundleID: nil, adapter: "linear"))

    section("AdapterMigration")
    check("never set, adapter file: on", AdapterMigration.enable(stored: nil, adapterFileExists: true, envFileExists: false) == true)
    check("never set, env file: on", AdapterMigration.enable(stored: nil, adapterFileExists: false, envFileExists: true) == true)
    check("never set, both (Jonni's Mac): on", AdapterMigration.enable(stored: nil, adapterFileExists: true, envFileExists: true) == true)
    check("never set, nothing: left off", AdapterMigration.enable(stored: nil, adapterFileExists: false, envFileExists: false) == nil)
    check("turned off by the user stays off", AdapterMigration.enable(stored: false, adapterFileExists: true, envFileExists: true) == nil)
    check("already on is left alone", AdapterMigration.enable(stored: true, adapterFileExists: false, envFileExists: false) == nil)

    section("AdapterLookup")
    let bundled = "/Applications/MainThing.app/Contents/Resources/adapters/linear"
    let lookup = AdapterLookup(enabledBuiltIns: ["linear": bundled])
    let folder = EventPlan.adaptersDirectory(config)
    let everything: (String) -> Bool = { _ in true }
    let nothing: (String) -> Bool = { _ in false }
    check("an enabled built-in runs the bundled script", lookup.source(for: "linear", configDirectory: config, exists: everything) == .builtIn(path: bundled))
    check("the bundled script runs with no file in the folder", lookup.source(for: "linear", configDirectory: config, exists: nothing) == .builtIn(path: bundled))
    check("a disabled built-in runs nothing, even with a file in the folder", lookup.source(for: "openbrain", configDirectory: config, exists: everything) == nil)
    check("a custom adapter is the folder file", lookup.source(for: "mytool", configDirectory: config, exists: everything) == .folder(path: folder.appendingPathComponent("mytool").path))
    check("a custom adapter without a file runs nothing", lookup.source(for: "mytool", configDirectory: config, exists: nothing) == nil)
    check("folder only keeps the old behavior for built-in names", AdapterLookup.folderOnly.source(for: "linear", configDirectory: config, exists: everything) == .folder(path: folder.appendingPathComponent("linear").path))
    check("resolve names: custom and enabled built-ins, sorted, shadowed and invalid dropped",
          lookup.resolveNames(folderNames: ["zed", "linear", "openbrain", "Bad", ".hidden", "a-1"]) == ["a-1", "linear", "zed"])
    check("resolve names: an enabled built-in with an empty folder", lookup.resolveNames(folderNames: []) == ["linear"])
    check("resolve names: nothing enabled, nothing in the folder", AdapterLookup().resolveNames(folderNames: []) == [])

    section("EventPlan with built-ins")
    let at = Date(timeIntervalSince1970: 0)
    func completed(_ ref: String) -> EventPayload {
        EventPayload(event: .taskCompleted, source: "notch", at: at, task: TaskItem("T", ref: ref), tasks: [])
    }
    let linearJobs = EventPlan.jobs(for: completed("linear:ENG-1"), configDirectory: config, lookup: lookup, exists: nothing)
    check("complete of a built-in ref runs the bundled script", linearJobs == [EventJob(kind: .adapter, name: "linear", path: bundled, arguments: ["complete", "ENG-1"], builtIn: true)])
    check("complete of a disabled built-in runs no adapter", EventPlan.jobs(for: completed("openbrain:x1"), configDirectory: config, lookup: lookup, exists: { !$0.hasSuffix("list-changed") && !$0.hasSuffix("task-completed") }).isEmpty)
    let custom = EventPlan.jobs(for: completed("mytool:9"), configDirectory: config, lookup: lookup, exists: everything)
    check("a custom adapter and the hook, as before", custom.map(\.label) == ["mytool", "task-completed hook"] && custom.allSatisfy { !$0.builtIn })
    let resolve = EventPlan.resolveJobs(url: "https://x.test", adapterNames: ["linear", "mytool"], configDirectory: config, lookup: lookup)
    check("resolve asks the bundled linear and the custom one", resolve.map(\.path) == [bundled, folder.appendingPathComponent("mytool").path])
    check("resolve jobs mark the built-in", resolve.map(\.builtIn) == [true, false])
    check("resolve jobs carry the verb", resolve.allSatisfy { $0.arguments == ["resolve", "https://x.test"] })

    section("AdapterEnvironment")
    let env = AdapterEnvironment.values(for: BuiltInAdapters.openBrain, stored: ["OPEN_BRAIN_API_URL": " https://x.convex.site ", "OPEN_BRAIN_API_KEY": "", "OTHER": "no"], configDirectory: config)
    check("set values pass, trimmed; empty ones and strangers do not", env == ["OPEN_BRAIN_API_URL": "https://x.convex.site", "MAIN_THING_CONFIG_DIR": "/Users/me/.config/main-thing"])
    check("the config dir always passes", AdapterEnvironment.values(for: BuiltInAdapters.linear, stored: [:], configDirectory: config) == ["MAIN_THING_CONFIG_DIR": "/Users/me/.config/main-thing"])
    let merged = AdapterEnvironment.merged(base: ["PATH": "/usr/bin", "OPEN_BRAIN_API_KEY": "from-launch", "HOME": "/Users/me"], adapter: BuiltInAdapters.openBrain, values: env)
    check("a launch value for a field is dropped when the app has none", merged["OPEN_BRAIN_API_KEY"] == nil)
    check("the app's values and the base stay", merged["OPEN_BRAIN_API_URL"] == "https://x.convex.site" && merged["PATH"] == "/usr/bin" && merged["HOME"] == "/Users/me")

    section("AdapterCheck")
    func outcome(_ exit: Int32?, stdout: String = "", stderr: String = "", timedOut: Bool = false) -> AdapterCheck.Outcome {
        AdapterCheck.outcome(adapter: "linear", record: RunRecord(at: at, exit: exit, ms: 3, timedOut: timedOut, stderr: stderr), stdout: Data(stdout.utf8))
    }
    check("exit 0 shows the first stdout line", outcome(0, stdout: "Signed in as Ana\nmore") == .ok("Signed in as Ana"))
    check("exit 0 with nothing says OK", outcome(0) == .ok("OK"))
    check("a failure shows stderr without the prefix", outcome(1, stderr: "linear: Linear API: Authentication required (HTTP 400)\nx") == .failed("Linear API: Authentication required (HTTP 400)"))
    check("a failure with no stderr names the exit", outcome(7) == .failed("Failed with exit 7."))
    check("exit 2 is an adapter without check", outcome(2, stderr: "linear: unknown verb 'check'") == .failed("This adapter has no check."))
    check("a timeout says so", outcome(nil, timedOut: true) == .failed("No answer in 10 seconds."))
    check("a start failure shows why", outcome(nil, stderr: "could not start: No such file") == .failed("could not start: No such file"))
    check("the prefix is only stripped for this adapter", AdapterCheck.firstLine("openbrain: x", adapter: "linear") == "openbrain: x")

    section("RunPermission for bundled scripts")
    let rootOwned = FileFacts(isRegularFile: true, ownerUID: 0, mode: 0o755)
    check("root owned is refused in the folder", RunPermission.problem(rootOwned, currentUID: 501) != nil)
    check("root owned is fine in the bundle", RunPermission.problem(rootOwned, currentUID: 501, allowRoot: true) == nil)
    check("another user is refused in the bundle too", RunPermission.problem(FileFacts(isRegularFile: true, ownerUID: 502, mode: 0o755), currentUID: 501, allowRoot: true) != nil)
    check("group writable is refused in the bundle too", RunPermission.problem(FileFacts(isRegularFile: true, ownerUID: 0, mode: 0o775), currentUID: 501, allowRoot: true) == "group or world writable")
}
