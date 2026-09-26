import Foundation

/// What the app tells hooks and adapters about.
public enum EventKind: String, Sendable, CaseIterable, Encodable {
    /// The current task was completed, from the notch, the API or the CLI.
    case taskCompleted = "task-completed"
    /// The list changed in any way, a completion included.
    case listChanged = "list-changed"
}

/// Who caused a change: `notch`, `api`, `cli`, or whatever the caller said (`?source=agent`).
public enum EventSource {
    public static let notch = "notch"
    public static let api = "api"
    /// The list editor's Save. A replace: removed tasks are deleted, never completed.
    public static let editor = "editor"
    public static let maxLength = 64

    /// Why a caller supplied source is not acceptable, or nil when it is. `[a-z0-9._-]{1,64}`.
    public static func problem(_ source: String) -> String? {
        if source.isEmpty { return "source must not be empty" }
        if source.count > maxLength { return "source is over \(maxLength) characters" }
        if !source.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }) {
            return "source must be [a-z0-9._-]"
        }
        return nil
    }
}

/// The JSON a hook or adapter reads on stdin:
/// `{"at":"2026-09-25T10:00:00.000Z","event":"task-completed","source":"notch","task":{...},"tasks":[...]}`.
/// `task` is present for `task-completed` only. `at` is ISO 8601 in UTC.
public struct EventPayload: Equatable, Sendable, Encodable {
    public var event: EventKind
    public var source: String
    public var at: Date
    public var task: TaskItem?
    public var tasks: [TaskItem]

    public init(event: EventKind, source: String, at: Date, task: TaskItem? = nil, tasks: [TaskItem]) {
        self.event = event
        self.source = source
        self.at = at
        self.task = task
        self.tasks = tasks
    }

    private enum CodingKeys: String, CodingKey { case event, source, at, task, tasks }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(event, forKey: .event)
        try container.encode(source, forKey: .source)
        try container.encode(EventPayload.iso8601(at), forKey: .at)
        try container.encodeIfPresent(task, forKey: .task)
        try container.encode(tasks, forKey: .tasks)
    }

    public func encoded() -> Data { JSONBody.encode(self) }

    /// `2026-09-25T10:00:00.123Z`.
    public static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// One thing to run for an event: a hook (`hooks/<event>`) or an adapter (`adapters/<name> complete <id>`).
public struct EventJob: Equatable, Sendable {
    public enum Kind: String, Sendable { case hook, adapter }

    public var kind: Kind
    /// The adapter name, or the event name for a hook.
    public var name: String
    public var path: String
    public var arguments: [String]

    public init(kind: Kind, name: String, path: String, arguments: [String] = []) {
        self.kind = kind
        self.name = name
        self.path = path
        self.arguments = arguments
    }

    /// How the failure line and the status report name it: "openbrain" or "list-changed hook".
    public var label: String { kind == .hook ? "\(name) hook" : name }
    /// Unique across kinds: "adapter:openbrain", "hook:list-changed".
    public var id: String { "\(kind.rawValue):\(name)" }
}

/// Pure planning of events and jobs. The app supplies the clock and the file system.
public enum EventPlan {
    /// The events one store change produces, in the order they run.
    /// A completion is `task-completed` then `list-changed`. Any other difference is `list-changed`.
    /// No difference, no events.
    public static func events(before: TaskList, after: TaskList, completed: TaskItem?, source: String, at: Date) -> [EventPayload] {
        if let completed {
            return [
                EventPayload(event: .taskCompleted, source: source, at: at, task: completed, tasks: after.tasks),
                EventPayload(event: .listChanged, source: source, at: at, tasks: after.tasks),
            ]
        }
        guard before.tasks != after.tasks else { return [] }
        return [EventPayload(event: .listChanged, source: source, at: at, tasks: after.tasks)]
    }

    /// The jobs one event runs, in order: the adapter for the completed task's ref first, when
    /// `adapters/<name>` exists, then `hooks/<event>` when it exists. `exists` answers for a path.
    public static func jobs(for payload: EventPayload, configDirectory: URL, exists: (String) -> Bool) -> [EventJob] {
        var jobs: [EventJob] = []
        if payload.event == .taskCompleted, let ref = payload.task?.ref, let parsed = TaskRef(ref) {
            let path = adaptersDirectory(configDirectory).appendingPathComponent(parsed.adapter).path
            if exists(path) {
                jobs.append(EventJob(kind: .adapter, name: parsed.adapter, path: path, arguments: ["complete", parsed.id]))
            }
        }
        let hook = hooksDirectory(configDirectory).appendingPathComponent(payload.event.rawValue).path
        if exists(hook) {
            jobs.append(EventJob(kind: .hook, name: payload.event.rawValue, path: hook))
        }
        return jobs
    }

    public static func hooksDirectory(_ configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent("hooks", isDirectory: true)
    }

    public static func adaptersDirectory(_ configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent("adapters", isDirectory: true)
    }
}

/// What the run rule looks at. Taken from `stat`, following symlinks, so a linked adapter is judged by its target.
public struct FileFacts: Equatable, Sendable {
    public var isRegularFile: Bool
    public var ownerUID: UInt32
    /// Permission bits, for example 0o755.
    public var mode: UInt16

    public init(isRegularFile: Bool, ownerUID: UInt32, mode: UInt16) {
        self.isRegularFile = isRegularFile
        self.ownerUID = ownerUID
        self.mode = mode
    }
}

/// The rule for running a hook or adapter: a regular file, owned by the user, executable by the
/// owner, writable by nobody else. Returns why not, or nil when it may run.
public enum RunPermission {
    public static func problem(_ facts: FileFacts?, currentUID: UInt32) -> String? {
        guard let facts else { return "not found" }
        if !facts.isRegularFile { return "not a regular file" }
        if facts.ownerUID != currentUID { return "owned by uid \(facts.ownerUID), not by you" }
        if facts.mode & 0o100 == 0 { return "not executable by the owner" }
        if facts.mode & 0o022 != 0 { return "group or world writable" }
        return nil
    }
}

/// The last run of one hook or adapter, for the log, the status route and the failure line.
public struct RunRecord: Equatable, Sendable, Encodable {
    public var at: Date
    /// Nil when the run was killed or never started.
    public var exit: Int32?
    public var ms: Int
    public var timedOut: Bool
    /// The first 2 KB.
    public var stderr: String

    public init(at: Date, exit: Int32?, ms: Int, timedOut: Bool = false, stderr: String = "") {
        self.at = at
        self.exit = exit
        self.ms = ms
        self.timedOut = timedOut
        self.stderr = stderr
    }

    public var ok: Bool { !timedOut && exit == 0 }

    private enum CodingKeys: String, CodingKey { case at, exit, ms, ok, stderr, timedOut }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(EventPayload.iso8601(at), forKey: .at)
        try container.encode(exit, forKey: .exit)
        try container.encode(ms, forKey: .ms)
        try container.encode(ok, forKey: .ok)
        try container.encode(stderr, forKey: .stderr)
        try container.encode(timedOut, forKey: .timedOut)
    }
}

/// One installed hook or adapter as `GET /status` reports it.
public struct InstalledEntry: Equatable, Sendable, Encodable {
    public var name: String
    public var path: String
    /// Why it will be skipped, from `RunPermission`, or nil when it may run.
    public var problem: String?
    public var lastRun: RunRecord?

    public init(name: String, path: String, problem: String? = nil, lastRun: RunRecord? = nil) {
        self.name = name
        self.path = path
        self.problem = problem
        self.lastRun = lastRun
    }
}

/// `GET /status`: what is installed, each one's last run, and which ones are failing right now.
public struct StatusReport: Equatable, Sendable, Encodable {
    public var adapters: [InstalledEntry]
    public var hooks: [InstalledEntry]
    /// Labels shown as "sync failed: <label>" in the open notch.
    public var failing: [String]

    public init(adapters: [InstalledEntry] = [], hooks: [InstalledEntry] = [], failing: [String] = []) {
        self.adapters = adapters
        self.hooks = hooks
        self.failing = failing
    }
}

/// Which hooks and adapters show "sync failed" in the notch: those whose last run failed, in the
/// order they first failed, until the same one succeeds again.
public struct FailureBoard: Equatable, Sendable {
    public private(set) var labels: [String] = []

    public init() {}

    public mutating func record(label: String, ok: Bool) {
        if ok {
            labels.removeAll { $0 == label }
        } else if !labels.contains(label) {
            labels.append(label)
        }
    }
}
