import AppKit
import MainThingCore
import ServiceManagement

/// The app's entry point, called from the `MainThing` executable's `main.swift`. The app lives in
/// this library so Xcode can render its previews: previews of an executable target need a build
/// setting SwiftPM cannot set.
public enum Launch {
    @MainActor
    public static func run() -> Never {
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

        // `MainThing --install-cli` links ~/.local/bin/main-thing to the command in the bundle and exits.
        // The same thing as Install Command Line Tool in the notch menu, for scripts.
        if CommandLine.arguments.contains("--install-cli") {
            do {
                print(try CommandLineTool.install().message)
                exit(0)
            } catch {
                print("install failed: \(error.localizedDescription)")
                exit(1)
            }
        }

        // `MainThing --bench-hover [seconds] [closed]` sweeps the rows with synthesized moves and exits.
        if let flag = CommandLine.arguments.firstIndex(of: "--bench-hover") {
            let seconds = flag + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[flag + 1]) ?? 5 : 5
            HoverBench.run(seconds: seconds, closed: CommandLine.arguments.contains("closed"), gap: CommandLine.arguments.contains("gap"))
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // LSUIElement in Info.plist does this for the bundle. Setting it here too covers `swift run`.
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0)
    }
}
