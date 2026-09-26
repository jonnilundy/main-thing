import Foundation

public struct BodyError: Error, Equatable, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

/// A refusal with its status: 400 for a bad body, 404 for a task that is not there.
public struct RouteFailure: Error, Equatable, Sendable {
    public let status: Int
    public let reason: String
    public init(_ status: Int, _ reason: String) {
        self.status = status
        self.reason = reason
    }
    public var response: HTTPResponse { .error(status, reason) }
}

/// Decodes a `PUT /tasks` body. Accepts `["A","B"]`, `[{"title":"A","ref":"openbrain:x"}]`, a mix,
/// or the same inside `{"tasks":[...]}`. Content-Type is ignored.
public enum BodyDecoding {
    public static func tasks(from body: Data) -> Result<[TaskItem], BodyError> {
        guard !body.isEmpty else {
            return .failure(BodyError("empty body, send a JSON array of tasks"))
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: body)
        } catch {
            return .failure(BodyError("body is not valid JSON"))
        }
        if let array = object as? [Any] {
            return items(array)
        }
        if let dict = object as? [String: Any] {
            guard let array = dict["tasks"] as? [Any] else {
                return .failure(BodyError("object needs a \"tasks\" array"))
            }
            return items(array)
        }
        return .failure(BodyError("body must be a JSON array of tasks or {\"tasks\":[...]}"))
    }

    private static func items(_ array: [Any]) -> Result<[TaskItem], BodyError> {
        var out: [TaskItem] = []
        var seenRefs: Set<String> = []
        for (i, element) in array.enumerated() {
            let task: TaskItem
            if let s = element as? String {
                task = TaskItem(s)
            } else if let dict = element as? [String: Any] {
                guard let title = dict["title"] as? String else {
                    return .failure(BodyError("item \(i) needs a \"title\" string"))
                }
                var ref: String?
                if let raw = dict["ref"], !(raw is NSNull) {
                    guard let s = raw as? String else {
                        return .failure(BodyError("item \(i) has a \"ref\" that is not a string"))
                    }
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        if let problem = TaskRef.problem(trimmed) {
                            return .failure(BodyError("item \(i): \(problem)"))
                        }
                        if !seenRefs.insert(trimmed).inserted {
                            return .failure(BodyError("item \(i) repeats the ref \(trimmed)"))
                        }
                        ref = trimmed
                    }
                }
                task = TaskItem(title, ref: ref)
            } else {
                return .failure(BodyError("item \(i) is not a string or a {\"title\",\"ref\"} object"))
            }
            out.append(task)
        }
        return .success(out)
    }
}

/// Pure routing. Takes a request and the current list, returns the response and the list after it.
public enum MainThingRouter {
    public static let allowedHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]", "main-thing.localhost"]

    public struct Outcome: Equatable, Sendable {
        public var response: HTTPResponse
        public var list: TaskList
        public var changed: Bool
        public var action: Action

        public init(response: HTTPResponse, list: TaskList, changed: Bool, action: Action = .none) {
            self.response = response
            self.list = list
            self.changed = changed
            self.action = action
        }
    }

    /// What the store must do to reach `list` from the list it was given, and who asked.
    /// The source is `api` unless the request said `?source=<name>`.
    public enum Action: Equatable, Sendable {
        case none
        case replace([TaskItem], source: String)
        /// Complete the row with this key.
        case complete(key: String, source: String)
    }

    /// Which row `POST /tasks/done` means. No body: the first. `{"index":N}`: 0 based.
    /// `{"ref":"openbrain:x"}`: the task with that ref. Nil result with a reason when it names nothing.
    public static func doneTarget(body: Data, list: TaskList) -> Result<String?, RouteFailure> {
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "{}" {
            return .success(list.rows.first?.key)
        }
        guard let object = try? JSONSerialization.jsonObject(with: body), let dict = object as? [String: Any] else {
            return .failure(RouteFailure(400, "body must be empty, {\"index\":N} or {\"ref\":\"<adapter>:<id>\"}"))
        }
        if let raw = dict["index"] {
            // JSON true and 1 both arrive as NSNumber; only a real boolean is refused.
            let isBool = (raw as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            guard !isBool, let n = raw as? Int else { return .failure(RouteFailure(400, "index must be a whole number, 0 based")) }
            guard n >= 0, let key = list.key(at: n) else {
                return .failure(RouteFailure(404, "no task at index \(n), the list has \(list.count)"))
            }
            return .success(key)
        }
        if let raw = dict["ref"] {
            guard let ref = raw as? String else { return .failure(RouteFailure(400, "ref must be a string")) }
            guard let key = list.key(ref: ref) else { return .failure(RouteFailure(404, "no task with ref \(ref)")) }
            return .success(key)
        }
        return .failure(RouteFailure(400, "body must be empty, {\"index\":N} or {\"ref\":\"<adapter>:<id>\"}"))
    }

    /// `[::1]:7788` -> `[::1]`, `localhost:7788` -> `localhost`. Lowercased.
    public static func hostWithoutPort(_ host: String) -> String {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("[") {
            guard let end = h.firstIndex(of: "]") else { return h }
            return String(h[...end])
        }
        if let colon = h.lastIndex(of: ":") {
            return String(h[..<colon])
        }
        return h
    }

    public static func hostAllowed(_ host: String?) -> Bool {
        guard let host else { return false }
        return allowedHosts.contains(hostWithoutPort(host))
    }

    /// The source a change is attributed to: `?source=<name>` when given and valid, else `api`.
    public static func source(of request: HTTPRequest) -> Result<String, BodyError> {
        guard let raw = request.query["source"] else { return .success(EventSource.api) }
        if let problem = EventSource.problem(raw) { return .failure(BodyError(problem)) }
        return .success(raw)
    }

    /// `port` is the one the API answers on; `GET /health` reports it.
    public static func handle(_ request: HTTPRequest, list: TaskList, status: StatusReport = StatusReport(), port: UInt16 = APIPort.fallback) -> Outcome {
        func unchanged(_ response: HTTPResponse) -> Outcome {
            Outcome(response: response, list: list, changed: false)
        }

        // Guards at the boundary. A browser page always sends Origin, so any Origin is refused.
        if request.header("origin") != nil {
            return unchanged(.error(403, "requests with an Origin header are refused"))
        }
        guard hostAllowed(request.header("host")) else {
            return unchanged(.error(403, "Host must be localhost, main-thing.localhost, 127.0.0.1 or [::1]"))
        }

        var path = request.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }

        switch path {
        case "/tasks":
            switch request.method {
            case "GET":
                return unchanged(.json(200, JSONBody.tasks(list)))
            case "PUT":
                let source: String
                switch MainThingRouter.source(of: request) {
                case .success(let s): source = s
                case .failure(let error): return unchanged(.error(400, error.reason))
                }
                switch BodyDecoding.tasks(from: request.body) {
                case .success(let tasks):
                    var next = list
                    next.replace(tasks)
                    return Outcome(response: .json(200, JSONBody.tasks(next)), list: next, changed: true, action: .replace(tasks, source: source))
                case .failure(let error):
                    return unchanged(.error(400, error.reason))
                }
            default:
                return unchanged(methodNotAllowed(request.method, path, allow: "GET, PUT"))
            }

        case "/tasks/done":
            guard request.method == "POST" else {
                return unchanged(methodNotAllowed(request.method, path, allow: "POST"))
            }
            let source: String
            switch MainThingRouter.source(of: request) {
            case .success(let s): source = s
            case .failure(let error): return unchanged(.error(400, error.reason))
            }
            let key: String?
            switch doneTarget(body: request.body, list: list) {
            case .success(let k): key = k
            case .failure(let failure): return unchanged(failure.response)
            }
            guard let key else {
                return Outcome(response: .json(200, JSONBody.tasks(list)), list: list, changed: false, action: .none)
            }
            var next = list
            next.complete(key: key, expected: nil)
            return Outcome(response: .json(200, JSONBody.tasks(next)), list: next, changed: true, action: .complete(key: key, source: source))

        case "/health":
            guard request.method == "GET" else {
                return unchanged(methodNotAllowed(request.method, path, allow: "GET"))
            }
            return unchanged(.json(200, JSONBody.health(port: port)))

        case "/status":
            guard request.method == "GET" else {
                return unchanged(methodNotAllowed(request.method, path, allow: "GET"))
            }
            return unchanged(.json(200, JSONBody.status(status)))

        default:
            return unchanged(.error(404, "no route for \(request.method) \(path)"))
        }
    }

    private static func methodNotAllowed(_ method: String, _ path: String, allow: String) -> HTTPResponse {
        .error(405, "\(method) is not allowed on \(path), use \(allow)", headers: ["Allow": allow])
    }
}
