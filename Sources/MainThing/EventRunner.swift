import Darwin
import Foundation
import MainThingCore
import Observation
import os

/// Runs hooks and adapters for events, off the main thread, one event at a time in event order.
///
/// Hooks live in `~/.config/mainthing/hooks/<event>`, adapters in `~/.config/mainthing/adapters/<name>`.
/// Each gets the event payload on stdin, 10 seconds to finish, then SIGKILL. The exit code, the
/// duration and the first 2 KB of stderr go to the log and to `EventStatus`. Nothing is retried.
final class EventRunner: @unchecked Sendable {
    static let timeout: TimeInterval = 10
    static let stderrLimit = 2048

    /// `~/.config/mainthing`, or `$XDG_CONFIG_HOME/mainthing`. `MAINTHING_CONFIG_DIR` overrides both.
    static var defaultConfigDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["MAINTHING_CONFIG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory() + "/.config"
        return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("mainthing", isDirectory: true)
    }

    let configDirectory: URL
    private let queue = DispatchQueue(label: MainThingBundleID + ".events", qos: .utility)
    private let log = Logger(subsystem: MainThingBundleID, category: "events")
    private let onResult: @Sendable (EventJob, RunRecord) -> Void

    /// `onResult` is called on the main actor after every run, permitted or not (a skipped file gets no call).
    init(configDirectory: URL = EventRunner.defaultConfigDirectory, onResult: @escaping @Sendable (EventJob, RunRecord) -> Void) {
        self.configDirectory = configDirectory
        self.onResult = onResult
    }

    /// Queues one event. Its jobs run in order after every event queued before it.
    func emit(_ payload: EventPayload) {
        queue.async { [self] in
            let jobs = EventPlan.jobs(for: payload, configDirectory: configDirectory) { FileManager.default.fileExists(atPath: $0) }
            if jobs.isEmpty {
                log.debug("\(payload.event.rawValue, privacy: .public) from \(payload.source, privacy: .public): nothing installed")
                return
            }
            let data = payload.encoded()
            for job in jobs {
                if let problem = RunPermission.problem(EventRunner.facts(of: job.path), currentUID: getuid()) {
                    log.error("skip \(job.kind.rawValue, privacy: .public) \(job.name, privacy: .public) at \(job.path, privacy: .public): \(problem, privacy: .public)")
                    continue
                }
                let record = run(job, stdin: data)
                let what = "\(job.kind.rawValue) \(job.name) \(job.arguments.joined(separator: " "))".trimmingCharacters(in: .whitespaces)
                if record.ok {
                    log.notice("\(what, privacy: .public) for \(payload.event.rawValue, privacy: .public): exit 0 in \(record.ms, privacy: .public) ms")
                } else if record.timedOut {
                    log.error("\(what, privacy: .public) for \(payload.event.rawValue, privacy: .public): killed after \(record.ms, privacy: .public) ms")
                } else {
                    log.error("\(what, privacy: .public) for \(payload.event.rawValue, privacy: .public): exit \(record.exit.map(String.init) ?? "signal", privacy: .public) in \(record.ms, privacy: .public) ms")
                }
                if !record.stderr.isEmpty, record.ok {
                    log.notice("\(what, privacy: .public) stderr: \(record.stderr, privacy: .public)")
                } else if !record.stderr.isEmpty {
                    log.error("\(what, privacy: .public) stderr: \(record.stderr, privacy: .public)")
                }
                let onResult = self.onResult
                DispatchQueue.main.async { onResult(job, record) }
            }
        }
    }

    /// `stat`, following symlinks. Nil when the path does not resolve.
    static func facts(of path: String) -> FileFacts? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileFacts(
            isRegularFile: (info.st_mode & S_IFMT) == S_IFREG,
            ownerUID: info.st_uid,
            mode: UInt16(info.st_mode & 0o7777)
        )
    }

    /// What is in the hooks and adapters folders right now, with the run rule applied to each.
    /// Last runs are filled in by `EventStatus`.
    func installed() -> (adapters: [InstalledEntry], hooks: [InstalledEntry]) {
        func scan(_ directory: URL) -> [InstalledEntry] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.filter { !$0.hasPrefix(".") }.sorted().map { name in
                let path = directory.appendingPathComponent(name).path
                return InstalledEntry(name: name, path: path, problem: RunPermission.problem(EventRunner.facts(of: path), currentUID: getuid()))
            }
        }
        return (scan(EventPlan.adaptersDirectory(configDirectory)), scan(EventPlan.hooksDirectory(configDirectory)))
    }

    private func run(_ job: EventJob, stdin payload: Data) -> RunRecord {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: job.path)
        process.arguments = job.arguments
        process.environment = EventRunner.childEnvironment()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return RunRecord(at: started, exit: nil, ms: 0, stderr: "could not start: \(error.localizedDescription)")
        }

        // Feed stdin and drain both outputs on other threads, so a child that ignores its input or
        // talks a lot never blocks this one. The write end never raises SIGPIPE in this process.
        let io = DispatchGroup()
        io.enter()
        DispatchQueue.global(qos: .utility).async {
            EventRunner.write(payload, to: input.fileHandleForWriting)
            io.leave()
        }
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        io.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.data = output.fileHandleForReading.readDataToEndOfFile()
            io.leave()
        }
        io.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.data = errors.fileHandleForReading.readDataToEndOfFile()
            io.leave()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + EventRunner.timeout) == .timedOut {
            timedOut = true
            kill(process.processIdentifier, SIGKILL)
            exited.wait()
        }
        let ms = Int((Date().timeIntervalSince(started) * 1000).rounded())
        // A grandchild holding the pipes open must not hold this queue forever.
        _ = io.wait(timeout: .now() + 2)
        let stdoutData = stdoutBox.data
        let stderrData = stderrBox.data
        let exit: Int32? = timedOut || process.terminationReason == .uncaughtSignal ? nil : process.terminationStatus
        let stderr = String(decoding: stderrData.prefix(EventRunner.stderrLimit), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdoutData.isEmpty {
            let head = String(decoding: stdoutData.prefix(EventRunner.stderrLimit), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            log.info("\(job.kind.rawValue, privacy: .public) \(job.name, privacy: .public) stdout: \(head, privacy: .public)")
        }
        return RunRecord(at: started, exit: exit, ms: ms, timedOut: timedOut, stderr: stderr)
    }

    /// The app's environment with the usual user tool folders on PATH. Launched from Login Items
    /// the app has only the system PATH, and hooks call `op`, `ob`, `node` and friends.
    static func childEnvironment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        let home = NSHomeDirectory()
        var parts = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"].reversed() where !parts.contains(extra) {
            parts.insert(extra, at: 0)
        }
        env["PATH"] = parts.joined(separator: ":")
        return env
    }

    /// Writes everything, then closes. EPIPE (the child never read) is fine and silent.
    private static func write(_ data: Data, to handle: FileHandle) {
        let fd = handle.fileDescriptor
        var on: Int32 = 1
        _ = fcntl(fd, F_SETNOSIGPIPE, &on)
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    break
                }
                offset += n
            }
        }
        try? handle.close()
    }
}

/// Output of one pipe, filled on a global queue, read after the group is done.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Main actor view of the runner: the last run of each hook and adapter, and which ones are
/// failing right now. The open notch reads `failing`.
@Observable
@MainActor
final class EventStatus {
    private(set) var lastRuns: [String: RunRecord] = [:]
    private var board = FailureBoard()

    var failing: [String] { board.labels }

    func record(_ job: EventJob, _ record: RunRecord) {
        lastRuns[job.id] = record
        board.record(label: job.label, ok: record.ok)
    }

    /// `GET /status`: the installed files with their last runs.
    func report(installed: (adapters: [InstalledEntry], hooks: [InstalledEntry])) -> StatusReport {
        func fill(_ entries: [InstalledEntry], kind: EventJob.Kind) -> [InstalledEntry] {
            entries.map { entry in
                var e = entry
                e.lastRun = lastRuns["\(kind.rawValue):\(entry.name)"]
                return e
            }
        }
        return StatusReport(
            adapters: fill(installed.adapters, kind: .adapter),
            hooks: fill(installed.hooks, kind: .hook),
            failing: failing
        )
    }
}
