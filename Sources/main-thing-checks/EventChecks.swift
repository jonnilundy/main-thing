import Foundation
import MainThingCore

@MainActor
func runEventChecks() {
    section("Events")
    let at = Date(timeIntervalSince1970: 1_790_000_000.5)
    let config = URL(fileURLWithPath: "/Users/me/.config/main-thing", isDirectory: true)

    do {
        check("ISO 8601 UTC with milliseconds", EventPayload.iso8601(at) == "2026-09-21T14:13:20.500Z")
        let done = EventPayload(event: .taskCompleted, source: "notch", at: at, task: TaskItem("A", ref: "openbrain:1"), tasks: ["B"])
        check("task-completed payload", String(decoding: done.encoded(), as: UTF8.self)
              == "{\"at\":\"2026-09-21T14:13:20.500Z\",\"event\":\"task-completed\",\"source\":\"notch\",\"task\":{\"ref\":\"openbrain:1\",\"title\":\"A\"},\"tasks\":[{\"title\":\"B\"}]}")
        let changed = EventPayload(event: .listChanged, source: "agent", at: at, tasks: [])
        check("list-changed payload has no task key", String(decoding: changed.encoded(), as: UTF8.self)
              == "{\"at\":\"2026-09-21T14:13:20.500Z\",\"event\":\"list-changed\",\"source\":\"agent\",\"tasks\":[]}")
    }

    do {
        check("source api by default", MainThingRouter.source(of: HTTPRequest(method: "PUT", path: "/tasks")) == .success("api"))
        check("source from the query", MainThingRouter.source(of: HTTPRequest(method: "PUT", path: "/tasks", query: ["source": "agent"])) == .success("agent"))
        check("source with a space is refused", EventSource.problem("my agent") == "source must be [a-z0-9._-]")
        check("empty source is refused", EventSource.problem("") != nil)
        check("65 character source is refused", EventSource.problem(String(repeating: "a", count: 65)) != nil)
        check("dotted source is fine", EventSource.problem("claude.code-1_x") == nil)
        check("query parsing decodes", HTTPRequest.parseQuery("source=agent&x=a%20b&flag") == ["source": "agent", "x": "a b", "flag": ""])
        var parser = HTTPRequestParser()
        if case .request(let req) = parser.feed(Data("POST /tasks/done?source=cli HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)) {
            check("parser keeps the query", req.path == "/tasks/done" && req.query == ["source": "cli"])
        } else {
            check("parser keeps the query", false)
        }
        let host = ["host": "localhost"]
        let put = MainThingRouter.handle(HTTPRequest(method: "PUT", path: "/tasks", headers: host, body: Data("[\"A\"]".utf8), query: ["source": "agent"]), list: TaskList())
        check("PUT ?source=agent reaches the action", put.action == .replace(["A"], source: "agent"))
        let done = MainThingRouter.handle(HTTPRequest(method: "POST", path: "/tasks/done", headers: host, query: ["source": "cli"]), list: TaskList(["A"]))
        check("POST /tasks/done ?source=cli reaches the action", done.action == .complete(key: "A#0", source: "cli"))
        let bad = MainThingRouter.handle(HTTPRequest(method: "POST", path: "/tasks/done", headers: host, query: ["source": "Bad One"]), list: TaskList(["A"]))
        check("bad source is 400 and changes nothing", bad.response.status == 400 && bad.changed == false && bad.action == .none)
    }

    do {
        let before = TaskList(["A", "B"])
        var after = before
        let removed = after.complete(expected: nil)
        let events = EventPlan.events(before: before, after: after, completed: removed, source: "notch", at: at)
        check("a completion is task-completed then list-changed", events.map(\.event) == [.taskCompleted, .listChanged])
        check("task-completed carries the task", events.first?.task == TaskItem("A") && events.first?.tasks == ["B"])
        check("list-changed after a completion carries no task", events.last?.task == nil && events.last?.source == "notch")
        var replaced = before
        replaced.replace(["B", "A"])
        check("a reorder is one list-changed", EventPlan.events(before: before, after: replaced, completed: nil, source: "api", at: at).map(\.event) == [.listChanged])
        check("the same list again is no event", EventPlan.events(before: before, after: before, completed: nil, source: "api", at: at).isEmpty)
    }

    do {
        let installed: Set<String> = [
            "/Users/me/.config/main-thing/adapters/openbrain",
            "/Users/me/.config/main-thing/hooks/task-completed",
            "/Users/me/.config/main-thing/hooks/list-changed",
        ]
        let exists: (String) -> Bool = { installed.contains($0) }
        let done = EventPayload(event: .taskCompleted, source: "cli", at: at, task: TaskItem("A", ref: "openbrain:md7abc"), tasks: [])
        let jobs = EventPlan.jobs(for: done, configDirectory: config, exists: exists)
        check("task-completed with a ref: adapter first, then the hook", jobs == [
            EventJob(kind: .adapter, name: "openbrain", path: "/Users/me/.config/main-thing/adapters/openbrain", arguments: ["complete", "md7abc"]),
            EventJob(kind: .hook, name: "task-completed", path: "/Users/me/.config/main-thing/hooks/task-completed"),
        ])
        let noAdapter = EventPayload(event: .taskCompleted, source: "cli", at: at, task: TaskItem("A", ref: "linear:X-1"), tasks: [])
        check("no adapter installed for the ref: hook only", EventPlan.jobs(for: noAdapter, configDirectory: config, exists: exists).map(\.kind) == [.hook])
        let noRef = EventPayload(event: .taskCompleted, source: "cli", at: at, task: TaskItem("A"), tasks: [])
        check("no ref: hook only", EventPlan.jobs(for: noRef, configDirectory: config, exists: exists).map(\.kind) == [.hook])
        let changed = EventPayload(event: .listChanged, source: "cli", at: at, task: TaskItem("A", ref: "openbrain:1"), tasks: [])
        check("list-changed never runs an adapter", EventPlan.jobs(for: changed, configDirectory: config, exists: exists) == [
            EventJob(kind: .hook, name: "list-changed", path: "/Users/me/.config/main-thing/hooks/list-changed"),
        ])
        check("nothing installed, no jobs", EventPlan.jobs(for: done, configDirectory: config, exists: { _ in false }).isEmpty)
        check("job labels", jobs.map(\.label) == ["openbrain", "task-completed hook"] && jobs.map(\.id) == ["adapter:openbrain", "hook:task-completed"])
    }

    do {
        let me: UInt32 = 501
        check("owner, 755: runs", RunPermission.problem(FileFacts(isRegularFile: true, ownerUID: me, mode: 0o755), currentUID: me) == nil)
        check("owner, 700: runs", RunPermission.problem(FileFacts(isRegularFile: true, ownerUID: me, mode: 0o700), currentUID: me) == nil)
        check("missing: not found", RunPermission.problem(nil, currentUID: me) == "not found")
        check("directory: not a regular file", RunPermission.problem(FileFacts(isRegularFile: false, ownerUID: me, mode: 0o755), currentUID: me) == "not a regular file")
        check("root owned: refused", RunPermission.problem(FileFacts(isRegularFile: true, ownerUID: 0, mode: 0o755), currentUID: me) == "owned by uid 0, not by you")
        check("644: not executable", RunPermission.problem(FileFacts(isRegularFile: true, ownerUID: me, mode: 0o644), currentUID: me) == "not executable by the owner")
        check("775: group writable", RunPermission.problem(FileFacts(isRegularFile: true, ownerUID: me, mode: 0o775), currentUID: me) == "group or world writable")
        check("757: world writable", RunPermission.problem(FileFacts(isRegularFile: true, ownerUID: me, mode: 0o757), currentUID: me) == "group or world writable")
        check("setuid bit does not matter, 4755 runs", RunPermission.problem(FileFacts(isRegularFile: true, ownerUID: me, mode: 0o4755), currentUID: me) == nil)
    }

    do {
        var board = FailureBoard()
        board.record(label: "openbrain", ok: false)
        board.record(label: "list-changed hook", ok: false)
        board.record(label: "openbrain", ok: false)
        check("failures are listed once, in order", board.labels == ["openbrain", "list-changed hook"])
        board.record(label: "openbrain", ok: true)
        check("a success clears that one", board.labels == ["list-changed hook"])
        board.record(label: "other", ok: true)
        check("a success of something never failed changes nothing", board.labels == ["list-changed hook"])
        let record = RunRecord(at: at, exit: 1, ms: 12, stderr: "boom")
        check("run record ok is exit 0 and no timeout", !record.ok && RunRecord(at: at, exit: 0, ms: 1).ok && !RunRecord(at: at, exit: nil, ms: 10_000, timedOut: true).ok)
        let report = StatusReport(
            adapters: [InstalledEntry(name: "openbrain", path: "/a/openbrain", lastRun: record)],
            hooks: [InstalledEntry(name: "list-changed", path: "/h/list-changed", problem: "group or world writable")],
            failing: ["openbrain"]
        )
        check("status body", String(decoding: JSONBody.status(report), as: UTF8.self)
              == "{\"adapters\":[{\"lastRun\":{\"at\":\"2026-09-21T14:13:20.500Z\",\"exit\":1,\"ms\":12,\"ok\":false,\"stderr\":\"boom\",\"timedOut\":false},\"name\":\"openbrain\",\"path\":\"/a/openbrain\"}],\"failing\":[\"openbrain\"],\"hooks\":[{\"name\":\"list-changed\",\"path\":\"/h/list-changed\",\"problem\":\"group or world writable\"}]}")
        let status = MainThingRouter.handle(HTTPRequest(method: "GET", path: "/status", headers: ["host": "localhost"]), list: TaskList(), status: report)
        check("GET /status returns the report", status.response.status == 200 && status.response.body == JSONBody.status(report))
        check("POST /status is 405", MainThingRouter.handle(HTTPRequest(method: "POST", path: "/status", headers: ["host": "localhost"]), list: TaskList()).response.status == 405)
    }
}
