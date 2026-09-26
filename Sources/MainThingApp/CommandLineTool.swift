import AppKit
import MainThingCore
import os

/// The `main-thing` command ships inside the bundle at Contents/Resources/main-thing.
/// Install links it into ~/.local/bin so it survives an app update in place.
@MainActor
enum CommandLineTool {
    private static let log = Logger(subsystem: MainThingBundleID, category: "cli")

    struct Outcome {
        var link: URL
        var onPath: Bool
        var message: String {
            var lines = ["Installed \(link.path) as a link to the command inside Main Thing."]
            if !onPath {
                lines.append("\(link.deletingLastPathComponent().path) is not on your PATH. Add this line to ~/.zshrc, then open a new terminal:")
                lines.append("export PATH=\"$HOME/.local/bin:$PATH\"")
            }
            return lines.joined(separator: "\n")
        }
    }

    static var source: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("main-thing")
    }

    static var binDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
    }

    /// Links ~/.local/bin/main-thing to the command in the bundle. Replaces whatever is there.
    static func install() throws -> Outcome {
        let files = FileManager.default
        guard let source, files.isExecutableFile(atPath: source.path) else {
            throw NSError(domain: "MainThing", code: 1, userInfo: [NSLocalizedDescriptionKey: "the command is not inside this app bundle"])
        }
        let dir = binDirectory
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("main-thing")
        if (try? link.checkResourceIsReachable()) == true || files.fileExists(atPath: link.path) || (try? files.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try files.removeItem(at: link)
        }
        try files.createSymbolicLink(at: link, withDestinationURL: source)
        let onPath = loginShellPath().split(separator: ":").contains { $0 == dir.path || $0 == "~/.local/bin" }
        log.notice("linked \(link.path, privacy: .public) to \(source.path, privacy: .public), on PATH: \(onPath, privacy: .public)")
        return Outcome(link: link, onPath: onPath)
    }

    /// PATH as the user's shell sets it, since the app itself starts with launchd's short one.
    static func loginShellPath() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ProcessInfo.processInfo.environment["PATH"] ?? ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Menu action: install and tell the user what happened.
    static func installFromMenu() {
        let alert = NSAlert()
        do {
            let outcome = try install()
            alert.messageText = "Command Line Tool installed"
            alert.informativeText = outcome.message
        } catch {
            alert.messageText = "Could not install the Command Line Tool"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            log.error("install failed: \(error.localizedDescription, privacy: .public)")
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
