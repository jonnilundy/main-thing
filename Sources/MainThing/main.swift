import AppKit
import MainThingCore
import ServiceManagement

// `MainThing --login status|enable|disable` reports or changes Launch at Login and exits.
// Runs before the app starts, so it works from a script against the installed bundle.
if let flag = CommandLine.arguments.firstIndex(of: "--login") {
    let command = flag + 1 < CommandLine.arguments.count ? CommandLine.arguments[flag + 1] : "status"
    do {
        switch command {
        case "status": break
        case "enable": try LaunchAtLogin.setEnabled(true)
        case "disable": try LaunchAtLogin.setEnabled(false)
        default:
            print("usage: MainThing --login status|enable|disable")
            exit(2)
        }
    } catch {
        print("launch at login \(command) failed: \(error.localizedDescription)")
        print("launch at login: \(LaunchAtLogin.describe(LaunchAtLogin.status))")
        exit(1)
    }
    print("launch at login: \(LaunchAtLogin.describe(LaunchAtLogin.status))")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// LSUIElement in Info.plist does this for the bundle. Setting it here too covers `swift run`.
app.setActivationPolicy(.accessory)
app.run()
