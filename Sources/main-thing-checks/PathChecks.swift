import Foundation
import MainThingCore

@MainActor
func runPathChecks() {
    section("AppPaths")
    let support = URL(fileURLWithPath: "/Users/me/Library/Application Support", isDirectory: true)
    let home = "/Users/me"
    let test = "com.jonnilundy.mainthing.test"
    let none: [String: String] = [:]

    check("version is x.y.z, with an optional -suffix for test builds", MainThingVersion.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?/) != nil)
    check("build is a positive integer", MainThingBuild >= 1)
    check("release bundle id", MainThingBundleID == "com.jonnilundy.mainthing")

    let real = AppPaths.tasksFile(environment: none, bundleID: MainThingBundleID, applicationSupport: support)
    check("release list is the real one", real.path == "/Users/me/Library/Application Support/MainThing/tasks.json")
    check("no bundle (swift run) is the release list", AppPaths.tasksFile(environment: none, bundleID: nil, applicationSupport: support) == real)
    let keyed = AppPaths.tasksFile(environment: none, bundleID: test, applicationSupport: support)
    check("test bundle id gets its own list", keyed.path == "/Users/me/Library/Application Support/MainThing-com.jonnilundy.mainthing.test/tasks.json")
    check("test list never is the real list", keyed != real && keyed.deletingLastPathComponent() != real.deletingLastPathComponent())
    check("the env file wins for a test id", AppPaths.tasksFile(environment: ["MAIN_THING_TASKS_FILE": "/tmp/t.json"], bundleID: test, applicationSupport: support).path == "/tmp/t.json")
    check("the env file wins for the release id", AppPaths.tasksFile(environment: ["MAIN_THING_TASKS_FILE": "/tmp/t.json"], bundleID: MainThingBundleID, applicationSupport: support).path == "/tmp/t.json")
    check("an empty env file is ignored", AppPaths.tasksFile(environment: ["MAIN_THING_TASKS_FILE": ""], bundleID: test, applicationSupport: support) == keyed)
    check("the old MAINTHING_ env name is ignored", AppPaths.tasksFile(environment: ["MAINTHING_TASKS_FILE": "/tmp/old.json"], bundleID: test, applicationSupport: support) == keyed)
    check("a lookalike id is a test id", AppPaths.isRelease(bundleID: "com.jonnilundy.mainthing2") == false)

    let config = AppPaths.configDirectory(environment: none, bundleID: MainThingBundleID, home: home)
    check("release config is ~/.config/main-thing", config.path == "/Users/me/.config/main-thing")
    check("test config is keyed", AppPaths.configDirectory(environment: none, bundleID: test, home: home).path == "/Users/me/.config/main-thing-com.jonnilundy.mainthing.test")
    check("XDG_CONFIG_HOME is kept for a test id", AppPaths.configDirectory(environment: ["XDG_CONFIG_HOME": "/x"], bundleID: test, home: home).path == "/x/main-thing-com.jonnilundy.mainthing.test")
    check("XDG_CONFIG_HOME for the release id", AppPaths.configDirectory(environment: ["XDG_CONFIG_HOME": "/x"], bundleID: nil, home: home).path == "/x/main-thing")
    check("the env config dir wins", AppPaths.configDirectory(environment: ["MAIN_THING_CONFIG_DIR": "/c"], bundleID: test, home: home).path == "/c")


    section("Env")
    check("the new name is read", Env.value("PORT", in: ["MAIN_THING_PORT": "1"]) == "1")
    check("empty is not set", Env.value("PORT", in: ["MAIN_THING_PORT": ""]) == nil)
    check("nothing set", Env.value("PORT", in: none) == nil)
    check("the old MAINTHING_ name is not read", Env.value("PORT", in: ["MAINTHING_PORT": "2"]) == nil)
}
