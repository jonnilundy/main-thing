import Darwin
import Foundation
import MainThingCore
import Observation
import os

/// Runs hooks and adapters for events, off the main thread, one event at a time in event order.
///
/// Hooks live in `~/.config/main-thing/hooks/<event>`, adapters in `~/.config/main-thing/adapters/<name>`.
/// Each gets the event payload on stdin, 10 seconds to finish, then SIGKILL. The exit code, the
/// duration and the first 2 KB of stderr go to the log and to `EventStatus`. Nothing is retried.
/// Child output is logged as private data: it can carry tokens or API error bodies.
final class EventRunner: @unchecked Sendable {
    static let timeout: TimeInterval = 10
    static let stderrLimit = 2048

    /// `~/.config/main-thing`, or `$XDG_CONFIG_HOME/main-thing`, keyed by bundle id for a test copy
    /// (`AppPaths`). `MAIN_THING_CONFIG_DIR` overrides both.
    static var defaultConfigDirectory: URL {
        AppPaths.configDirectory(environment: ProcessInfo.processInfo.environment, bundleID: Bundle.main.bundleIdentifier, home: NSHomeDirectory())
    }

    /// Before 0.3 the release app's config folder was `~/.config/mainthing`. Moves it, with its
    /// adapters, hooks, sounds and env files, to the new folder and leaves a link at the old path,
    /// so anything that still points there keeps working.
    static func moveLegacyConfigIfNeeded() {
        let files = FileManager.default
        let log = Logger(subsystem: MainThingBundleID, category: "events")
        guard let legacy = AppPaths.legacyConfigDirectory(
            environment: ProcessInfo.processInfo.environment, bundleID: Bundle.main.bundleIdentifier, home: NSHomeDirectory()
        ) else { return }
        let target = defaultConfigDirectory
        var isDirectory: ObjCBool = false
        let legacyIsLink = (try? files.destinationOfSymbolicLink(atPath: legacy.path)) != nil
        let legacyIsFolder = files.fileExists(atPath: legacy.path, isDirectory: &isDirectory) && isDirectory.boolValue
        let newExists = files.fileExists(atPath: target.path) || (try? files.destinationOfSymbolicLink(atPath: target.path)) != nil
        guard AppPaths.movesLegacyConfig(legacyIsFolder: legacyIsFolder, legacyIsLink: legacyIsLink, newExists: newExists) else { return }
        do {
            try files.moveItem(at: legacy, to: target)
            try files.createSymbolicLink(at: legacy, withDestinationURL: target)
            log.notice("moved the config folder \(legacy.path, privacy: .public) to \(target.path, privacy: .public), link left at the old path")
        } catch {
            log.error("could not move the config folder \(legacy.path, privacy: .public) to \(target.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
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
                    log.notice("\(what, privacy: .public) stderr: \(record.stderr, privacy: .private)")
                } else if !record.stderr.isEmpty {
                    log.error("\(what, privacy: .public) stderr: \(record.stderr, privacy: .private)")
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

    /// After the timeout the group gets SIGTERM, and SIGKILL this much later if it is still there.
    static let termGrace: TimeInterval = 1

    /// Runs one job in its own process group, so a timeout kills the hook and everything it
    /// started, not just the shell at the top.
    private func run(_ job: EventJob, stdin payload: Data) -> RunRecord {
        let started = Date()
        guard let stdinPipe = EventRunner.pipe(), let stdoutPipe = EventRunner.pipe(), let stderrPipe = EventRunner.pipe() else {
            return RunRecord(at: started, exit: nil, ms: 0, stderr: "could not open pipes")
        }
        let pid: pid_t
        switch EventRunner.spawn(
            path: job.path, arguments: job.arguments, environment: EventRunner.childEnvironment(),
            stdin: stdinPipe.read, stdout: stdoutPipe.write, stderr: stderrPipe.write
        ) {
        case .success(let p): pid = p
        case .failure(let error):
            for fd in [stdinPipe.read, stdinPipe.write, stdoutPipe.read, stdoutPipe.write, stderrPipe.read, stderrPipe.write] { close(fd) }
            return RunRecord(at: started, exit: nil, ms: 0, stderr: "could not start: \(error.localizedDescription)")
        }
        // The child holds its ends now.
        close(stdinPipe.read)
        close(stdoutPipe.write)
        close(stderrPipe.write)

        // Feed stdin and drain both outputs on other threads, so a child that ignores its input or
        // talks a lot never blocks this one. The write end never raises SIGPIPE in this process.
        let io = DispatchGroup()
        io.enter()
        DispatchQueue.global(qos: .utility).async {
            EventRunner.write(payload, to: FileHandle(fileDescriptor: stdinPipe.write, closeOnDealloc: true))
            io.leave()
        }
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        io.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.data = FileHandle(fileDescriptor: stdoutPipe.read, closeOnDealloc: true).readDataToEndOfFile()
            io.leave()
        }
        io.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.data = FileHandle(fileDescriptor: stderrPipe.read, closeOnDealloc: true).readDataToEndOfFile()
            io.leave()
        }

        // One thread waits for the child; this one waits on it with the timeout.
        let exited = DispatchSemaphore(value: 0)
        let statusBox = StatusBox()
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            statusBox.status = status
            exited.signal()
        }
        var timedOut = false
        if exited.wait(timeout: .now() + EventRunner.timeout) == .timedOut {
            timedOut = true
            killpg(pid, SIGTERM)
            if exited.wait(timeout: .now() + EventRunner.termGrace) == .timedOut {
                killpg(pid, SIGKILL)
                exited.wait()
            }
            // Whatever the child left behind in the group is gone too, or goes now.
            killpg(pid, SIGKILL)
        }
        let ms = Int((Date().timeIntervalSince(started) * 1000).rounded())
        // A stray process holding the pipes open must not hold this queue forever.
        _ = io.wait(timeout: .now() + 2)
        let stdoutData = stdoutBox.data
        let stderrData = stderrBox.data

        let status = statusBox.status
        let exitedNormally = (status & 0x7f) == 0
        let exit: Int32? = timedOut || !exitedNormally ? nil : (status >> 8) & 0xff
        let stderr = String(decoding: stderrData.prefix(EventRunner.stderrLimit), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdoutData.isEmpty {
            let head = String(decoding: stdoutData.prefix(EventRunner.stderrLimit), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            log.info("\(job.kind.rawValue, privacy: .public) \(job.name, privacy: .public) stdout: \(head, privacy: .private)")
        }
        return RunRecord(at: started, exit: exit, ms: ms, timedOut: timedOut, stderr: stderr)
    }

    /// A pipe with both ends close-on-exec; the spawn dup2s the child's end into place.
    private static func pipe() -> (read: Int32, write: Int32)? {
        var fds: [Int32] = [0, 0]
        guard Darwin.pipe(&fds) == 0 else { return nil }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (fds[0], fds[1])
    }

    /// posix_spawn into a new process group (the child's pid), with only the three standard
    /// descriptors open. Returns the pid.
    private static func spawn(path: String, arguments: [String], environment: [String: String], stdin: Int32, stdout: Int32, stderr: Int32) -> Result<pid_t, NSError> {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for p in argv { free(p) }
            for p in envp { free(p) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        if rc != 0 {
            return .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(rc), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(rc))]))
        }
        return .success(pid)
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

/// The child's wait status, filled by the waiting thread.
private final class StatusBox: @unchecked Sendable {
    var status: Int32 = 0
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
