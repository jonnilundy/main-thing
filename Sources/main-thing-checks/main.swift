import Foundation
import MainThingCore

// Assertion runner. `import Testing` and XCTest are not available without Xcode.
var failures = 0
var passes = 0

@MainActor
func check(_ name: String, _ condition: @autoclosure () -> Bool, file: String = #fileID, line: Int = #line) {
    if condition() {
        passes += 1
    } else {
        failures += 1
        print("FAIL \(name)  (\(file):\(line))")
    }
}

func section(_ name: String) { print("-- \(name)") }

func request(
    _ method: String, _ path: String, host: String? = "127.0.0.1:7788",
    headers: [String: String] = [:], body: String = ""
) -> HTTPRequest {
    var h = headers
    if let host { h["host"] = host }
    return HTTPRequest(method: method, path: path, headers: h, body: Data(body.utf8))
}

func text(_ response: HTTPResponse) -> String { response.bodyText }

// MARK: TaskList

section("TaskList")
do {
    let list = TaskList(["  A ", "", "   ", "B", "\n"])
    check("init trims and drops blanks", list.titles == ["A", "B"])
    check("current is index 0", list.current == "A")
    check("count", list.count == 2)
    check("empty list has no current", TaskList().current == nil && TaskList().isEmpty)
    check("legacy data: copy when the new file is missing and the old one exists", LegacyData.shouldCopy(newExists: false, legacyExists: true))
    check("legacy data: no copy when the new file exists", LegacyData.shouldCopy(newExists: true, legacyExists: true) == false)
    check("legacy data: no copy without an old file", LegacyData.shouldCopy(newExists: false, legacyExists: false) == false)
    check("legacy data: the old folder is NextUp", LegacyData.legacyDirectoryName == "NextUp")
}
do {
    var list = TaskList(["M", "M", "X"])
    check("duplicate titles get different keys", list.rows.map(\.key) == ["M#0", "M#1", "X#0"])
    check("row id is the key", list.rows[1].id == "M#1")
    let before = Array(list.rows.dropFirst())
    check("complete(nil) removes index 0 and returns it", list.complete(expected: nil) == TaskItem("M"))
    check("remaining keys are unchanged after done", list.rows == before)
    check("remaining keys after done", list.rows.map(\.key) == ["M#1", "X#0"])
    check("complete with a stale title does nothing", list.complete(expected: "Not this") == nil)
    check("list unchanged after stale done", list.rows.map(\.key) == ["M#1", "X#0"])
    check("complete with the matching title works", list.complete(expected: "M") != nil)
    check("after matching done", list.rows.map(\.key) == ["X#0"])
    list.complete(expected: nil)
    check("complete on empty is a no op", list.complete(expected: nil) == nil && list.isEmpty)
}
do {
    var list = TaskList(["A", "B"])
    let a = list.rows[0]
    list.replace(["A", "C"])
    check("replace that changes another title keeps the key", list.rows[0] == a)
    check("replace assigns new titles fresh keys", list.rows.map(\.key) == ["A#0", "C#0"])
    list.replace(["C", "A"])
    check("reorder keeps keys", list.rows.map(\.key) == ["C#0", "A#0"])
    list.replace(["  A  ", "", "D"])
    check("replace trims and drops blanks", list.titles == ["A", "D"])
    check("replace keeps A's key through trimming", list.rows[0].key == "A#0")
}
do {
    var list = TaskList(["M", "M"])
    list.complete(expected: nil)
    check("survivor of duplicate done keeps #1", list.rows.map(\.key) == ["M#1"])
    list.replace(["M", "M"])
    check("re-adding a duplicate reuses #1 and mints the lowest free number", list.rows.map(\.key) == ["M#1", "M#0"])
    list.replace(["M", "M", "M"])
    check("third duplicate gets #2", list.rows.map(\.key) == ["M#1", "M#0", "M#2"])
}

// MARK: Refs

section("TaskRef")
do {
    let ref = TaskRef("openbrain:md7abc")
    check("ref parses into adapter and id", ref?.adapter == "openbrain" && ref?.id == "md7abc")
    check("id may hold colons", TaskRef("a:b:c")?.id == "b:c")
    check("adapter may hold digits and dashes", TaskRef("linear-2:ISS-12") != nil)
    check("no colon is refused", TaskRef.problem("openbrain") == "ref must look like <adapter>:<id>")
    check("empty adapter is refused", TaskRef.problem(":x") != nil && TaskRef(":x") == nil)
    check("uppercase adapter is refused", TaskRef.problem("OpenBrain:x") != nil)
    check("underscore in adapter is refused", TaskRef.problem("open_brain:x") != nil)
    check("empty id is refused", TaskRef.problem("openbrain:") == "ref has no id after the colon")
    check("space in id is refused", TaskRef.problem("openbrain:a b") != nil)
    check("256 characters is fine", TaskRef.problem("ob:" + String(repeating: "x", count: 253)) == nil)
    check("257 characters is refused", TaskRef.problem("ob:" + String(repeating: "x", count: 254)) == "ref is over 256 characters")
}
do {
    var list = TaskList([TaskItem("A", ref: "openbrain:1"), "B", TaskItem("C", ref: "openbrain:2")])
    check("ref'd rows are keyed by ref, others by title", list.rows.map(\.key) == ["ref:openbrain:1", "B#0", "ref:openbrain:2"])
    check("tasks round trip", list.tasks == [TaskItem("A", ref: "openbrain:1"), "B", TaskItem("C", ref: "openbrain:2")])
    list.replace([TaskItem("A renamed", ref: "openbrain:1"), "B", TaskItem("C", ref: "openbrain:2")])
    check("rename of a ref'd task keeps its key", list.rows[0].key == "ref:openbrain:1" && list.rows[0].title == "A renamed")
    list.replace(["B", TaskItem("A renamed", ref: "openbrain:1")])
    check("reorder with a ref keeps keys", list.rows.map(\.key) == ["B#0", "ref:openbrain:1"])
    list.replace(["A renamed", TaskItem("A renamed", ref: "openbrain:1")])
    check("same title with and without a ref are different rows", list.rows.map(\.key) == ["A renamed#0", "ref:openbrain:1"])
    let done = list.complete(expected: nil)
    check("complete returns the removed task", done == TaskItem("A renamed"))
    check("complete keeps the ref of the survivor", list.rows.map(\.key) == ["ref:openbrain:1"])
    list.replace([TaskItem(" Spaced ", ref: "  openbrain:9 "), TaskItem("Empty ref", ref: "   ")])
    check("clean trims the ref and drops an empty one", list.tasks == [TaskItem("Spaced", ref: "openbrain:9"), "Empty ref"])
}
do {
    let decoder = JSONDecoder()
    let old = try? decoder.decode([TaskItem].self, from: Data("[\"A\",\"B\"]".utf8))
    check("old tasks.json of strings still loads", old == ["A", "B"])
    let mixed = try? decoder.decode([TaskItem].self, from: Data("[\"A\",{\"title\":\"B\",\"ref\":\"openbrain:x\"},{\"title\":\"C\"}]".utf8))
    check("objects and strings load together", mixed == ["A", TaskItem("B", ref: "openbrain:x"), "C"])
    let encoded = String(decoding: JSONBody.encode([TaskItem("A"), TaskItem("B", ref: "openbrain:x")]), as: UTF8.self)
    check("encoding leaves out a missing ref", encoded == "[{\"title\":\"A\"},{\"ref\":\"openbrain:x\",\"title\":\"B\"}]")
    let body = String(decoding: JSONBody.tasks(TaskList(["A", TaskItem("B", ref: "openbrain:md7abc")])), as: UTF8.self)
    check("GET /tasks body shape", body == "{\"tasks\":[{\"title\":\"A\"},{\"ref\":\"openbrain:md7abc\",\"title\":\"B\"}]}")
}

// MARK: Request parsing

section("HTTPRequestParser")
do {
    var parser = HTTPRequestParser()
    let step = parser.feed(Data("GET /tasks?x=1 HTTP/1.1\r\nHost: 127.0.0.1:7788\r\nUser-Agent: curl/8\r\n\r\n".utf8))
    if case .request(let req) = step {
        check("method", req.method == "GET")
        check("query is stripped", req.path == "/tasks")
        check("headers are lowercased and trimmed", req.header("HOST") == "127.0.0.1:7788" && req.headers["user-agent"] == "curl/8")
        check("no body", req.body.isEmpty)
    } else {
        check("one chunk GET parses", false)
    }
}
do {
    var parser = HTTPRequestParser()
    let raw = "PUT /tasks HTTP/1.1\r\nHost: localhost:7788\r\nContent-Length: 9\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\n[\"A\",\"B\"]"
    let step = parser.feed(Data(raw.utf8))
    if case .request(let req) = step {
        check("PUT body by Content-Length", String(decoding: req.body, as: UTF8.self) == "[\"A\",\"B\"]")
    } else {
        check("one chunk PUT parses", false)
    }
}
do {
    var parser = HTTPRequestParser()
    let chunks = [
        "PUT /ta",
        "sks HTTP/1.1\r\nHost: 127.0.0.1:7788\r\nContent-Le",
        "ngth: 13\r\n\r\n",
        "[\"Split",
        "\",\"B\"]",
    ]
    var steps: [HTTPRequestParser.Step] = []
    for chunk in chunks { steps.append(parser.feed(Data(chunk.utf8))) }
    check("split chunks: first four need more", steps.dropLast().allSatisfy { $0 == .needMore })
    if case .request(let req) = steps.last! {
        check("split chunks: assembled body", String(decoding: req.body, as: UTF8.self) == "[\"Split\",\"B\"]")
        check("split chunks: path", req.path == "/tasks" && req.method == "PUT")
    } else {
        check("split chunks: final chunk completes the request", false)
    }
}
do {
    var parser = HTTPRequestParser()
    _ = parser.feed(Data("PUT /tasks HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\n\r\n".utf8))
    let step = parser.feed(Data("[\"A\"]extra".utf8))
    if case .request(let req) = step {
        check("body stops at Content-Length", req.body == Data("[\"A\"]".utf8))
    } else {
        check("body arriving after the head completes", false)
    }
}
do {
    var parser = HTTPRequestParser()
    let step = parser.feed(Data("PUT /tasks HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 65537\r\n\r\n".utf8))
    check("over 64 KB is 413 before the body arrives", step == .failure(.error(413, "body over 64 KB")))
    var ok = HTTPRequestParser()
    let atLimit = ok.feed(Data("PUT /tasks HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 65536\r\n\r\n".utf8))
    check("exactly 64 KB waits for the body", atLimit == .needMore)
}
do {
    var parser = HTTPRequestParser()
    let step = parser.feed(Data("PUT /tasks HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: abc\r\n\r\n".utf8))
    if case .failure(let r) = step { check("bad Content-Length is 400", r.status == 400) } else { check("bad Content-Length fails", false) }
}
do {
    var parser = HTTPRequestParser()
    let step = parser.feed(Data("GARBAGE\r\n\r\n".utf8))
    if case .failure(let r) = step { check("malformed request line is 400", r.status == 400) } else { check("malformed request line fails", false) }
    var p2 = HTTPRequestParser()
    let s2 = p2.feed(Data("GET /x HTTP/1.1\r\nNoColonHere\r\n\r\n".utf8))
    if case .failure(let r) = s2 { check("header without colon is 400", r.status == 400) } else { check("header without colon fails", false) }
    var p3 = HTTPRequestParser()
    let s3 = p3.feed(Data("PUT /tasks HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
    if case .failure(let r) = s3 { check("chunked encoding is 400", r.status == 400) } else { check("chunked encoding fails", false) }
}
do {
    var parser = HTTPRequestParser()
    let huge = "GET /tasks HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: 17_000)
    let step = parser.feed(Data(huge.utf8))
    if case .failure(let r) = step { check("head over 16 KB is 431", r.status == 431) } else { check("oversized head fails", false) }
}

// MARK: Body decoding

section("BodyDecoding")
check("array body", BodyDecoding.tasks(from: Data("[\"A\",\" B \"]".utf8)) == .success(["A", " B "]))
check("object body", BodyDecoding.tasks(from: Data("{\"tasks\":[\"A\"]}".utf8)) == .success(["A"]))
check("empty array", BodyDecoding.tasks(from: Data("[]".utf8)) == .success([]))
check("bad JSON", BodyDecoding.tasks(from: Data("not json".utf8)) == .failure(BodyError("body is not valid JSON")))
check("non-string item", BodyDecoding.tasks(from: Data("[\"A\",2]".utf8)) == .failure(BodyError("item 1 is not a string or a {\"title\",\"ref\"} object")))
check("object items", BodyDecoding.tasks(from: Data("[{\"title\":\"A\"},{\"title\":\"B\",\"ref\":\"openbrain:x\"}]".utf8)) == .success(["A", TaskItem("B", ref: "openbrain:x")]))
check("mixed strings and objects", BodyDecoding.tasks(from: Data("[\"A\",{\"title\":\"B\",\"ref\":\"openbrain:x\"}]".utf8)) == .success(["A", TaskItem("B", ref: "openbrain:x")]))
check("object inside the tasks form", BodyDecoding.tasks(from: Data("{\"tasks\":[{\"title\":\"A\",\"ref\":\"ob:1\"}]}".utf8)) == .success([TaskItem("A", ref: "ob:1")]))
check("null ref is no ref", BodyDecoding.tasks(from: Data("[{\"title\":\"A\",\"ref\":null}]".utf8)) == .success(["A"]))
check("empty ref is no ref", BodyDecoding.tasks(from: Data("[{\"title\":\"A\",\"ref\":\"\"}]".utf8)) == .success(["A"]))
check("object without title", BodyDecoding.tasks(from: Data("[{\"ref\":\"ob:1\"}]".utf8)) == .failure(BodyError("item 0 needs a \"title\" string")))
check("ref that is not a string", BodyDecoding.tasks(from: Data("[{\"title\":\"A\",\"ref\":5}]".utf8)) == .failure(BodyError("item 0 has a \"ref\" that is not a string")))
check("bad ref shape is 400 with the reason", BodyDecoding.tasks(from: Data("[{\"title\":\"A\",\"ref\":\"nocolon\"}]".utf8)) == .failure(BodyError("item 0: ref must look like <adapter>:<id>")))
check("bad adapter name", BodyDecoding.tasks(from: Data("[{\"title\":\"A\",\"ref\":\"Open_Brain:x\"}]".utf8)) == .failure(BodyError("item 0: ref adapter name must be [a-z0-9-]+ before the colon")))
check("ref over 256 characters", BodyDecoding.tasks(from: Data(("[{\"title\":\"A\",\"ref\":\"ob:" + String(repeating: "x", count: 254) + "\"}]").utf8)) == .failure(BodyError("item 0: ref is over 256 characters")))
check("duplicate ref in one body", BodyDecoding.tasks(from: Data("[{\"title\":\"A\",\"ref\":\"ob:1\"},{\"title\":\"B\",\"ref\":\"ob:1\"}]".utf8)) == .failure(BodyError("item 1 repeats the ref ob:1")))
check("object without tasks", BodyDecoding.tasks(from: Data("{\"x\":1}".utf8)) == .failure(BodyError("object needs a \"tasks\" array")))
check("top level string", BodyDecoding.tasks(from: Data("\"A\"".utf8)).isFailure)
check("empty body", BodyDecoding.tasks(from: Data()) == .failure(BodyError("empty body, send a JSON array of tasks")))

extension Result { var isFailure: Bool { if case .failure = self { true } else { false } } }

// MARK: Routing and guards

section("MainThingRouter")
do {
    let list = TaskList(["A", "B"])
    let out = MainThingRouter.handle(request("GET", "/tasks"), list: list)
    check("GET /tasks", out.response.status == 200 && text(out.response) == "{\"tasks\":[{\"title\":\"A\"},{\"title\":\"B\"}]}" && out.changed == false)
    let slash = MainThingRouter.handle(request("GET", "/tasks/"), list: list)
    check("trailing slash is tolerated", slash.response.status == 200)
}
do {
    let list = TaskList(["A"])
    let out = MainThingRouter.handle(request("PUT", "/tasks", body: "[\" X \", \"\", \"Y\"]"), list: list)
    check("PUT array replaces, trims, drops blanks", out.response.status == 200 && text(out.response) == "{\"tasks\":[{\"title\":\"X\"},{\"title\":\"Y\"}]}")
    check("PUT reports changed", out.changed && out.list.titles == ["X", "Y"])
    let obj = MainThingRouter.handle(request("PUT", "/tasks", body: "{\"tasks\":[\"Z\"]}"), list: list)
    check("PUT object form", obj.list.titles == ["Z"])
    let refs = MainThingRouter.handle(request("PUT", "/tasks", body: "[\"A\",{\"title\":\"B\",\"ref\":\"openbrain:md7abc\"}]"), list: list)
    check("PUT with refs echoes objects", text(refs.response) == "{\"tasks\":[{\"title\":\"A\"},{\"ref\":\"openbrain:md7abc\",\"title\":\"B\"}]}")
    check("PUT with refs asks the store for the tasks", refs.action == .replace(["A", TaskItem("B", ref: "openbrain:md7abc")], source: "api"))
    let badRef = MainThingRouter.handle(request("PUT", "/tasks", body: "[{\"title\":\"B\",\"ref\":\"bad ref\"}]"), list: list)
    check("PUT with a bad ref is 400 with a one line reason", badRef.response.status == 400 && text(badRef.response) == "{\"error\":\"item 0: ref must look like <adapter>:<id>\"}" && badRef.changed == false)
    let bad = MainThingRouter.handle(request("PUT", "/tasks", body: "{oops"), list: list)
    check("PUT bad JSON is 400 with a reason", bad.response.status == 400 && text(bad.response) == "{\"error\":\"body is not valid JSON\"}" && bad.changed == false)
    check("PUT bad JSON leaves the list", bad.list == list)
}
do {
    let list = TaskList(["A", "B"])
    let out = MainThingRouter.handle(request("POST", "/tasks/done"), list: list)
    check("POST /tasks/done removes index 0", text(out.response) == "{\"tasks\":[{\"title\":\"B\"}]}" && out.changed && out.list.titles == ["B"])
    let empty = MainThingRouter.handle(request("POST", "/tasks/done"), list: TaskList())
    check("POST /tasks/done on empty is 200 and unchanged", empty.response.status == 200 && text(empty.response) == "{\"tasks\":[]}" && empty.changed == false)
}
do {
    // The version is whatever Version.swift says, so a release bump keeps these passing.
    let body7788 = "{\"ok\":true,\"port\":7788,\"version\":\"\(MainThingVersion)\"}"
    let out = MainThingRouter.handle(request("GET", "/health"), list: TaskList())
    check("GET /health exact body, port 7788 by default", out.response.status == 200 && text(out.response) == body7788)
    let on80 = MainThingRouter.handle(request("GET", "/health", host: "main-thing.localhost"), list: TaskList(), port: 80)
    check("GET /health reports the port it was given", text(on80.response) == "{\"ok\":true,\"port\":80,\"version\":\"\(MainThingVersion)\"}")
    let wire = String(decoding: out.response.serialized(), as: UTF8.self)
    check("serialized status line", wire.hasPrefix("HTTP/1.1 200 OK\r\n"))
    check("serialized content length", wire.contains("\r\nContent-Length: \(body7788.utf8.count)\r\n"))
    check("serialized closes the connection", wire.contains("\r\nConnection: close\r\n"))
    check("serialized body after blank line", wire.hasSuffix("\r\n\r\n" + body7788))
}
do {
    check("ports: 80 then 7788 by default", APIPort.candidates(environment: nil, defaultsValue: 0) == [80, 7788])
    check("ports: MAIN_THING_PORT alone", APIPort.candidates(environment: "7799", defaultsValue: 0) == [7799])
    check("ports: the defaults override alone", APIPort.candidates(environment: nil, defaultsValue: 7799) == [7799])
    check("ports: the environment wins over the defaults", APIPort.candidates(environment: "8080", defaultsValue: 7799) == [8080])
    check("ports: a bad environment value falls back to the defaults", APIPort.candidates(environment: "abc", defaultsValue: 7799) == [7799])
    check("ports: out of range is ignored", APIPort.candidates(environment: "70000", defaultsValue: -1) == [80, 7788])
    check("ports: 80 can be pinned", APIPort.candidates(environment: "80", defaultsValue: 0) == [80])
}
do {
    let list = TaskList(["A"])
    check("404 unknown route", MainThingRouter.handle(request("GET", "/nope"), list: list).response.status == 404)
    let del = MainThingRouter.handle(request("DELETE", "/tasks"), list: list)
    check("405 DELETE /tasks", del.response.status == 405 && del.response.headers["Allow"] == "GET, PUT")
    check("405 GET /tasks/done", MainThingRouter.handle(request("GET", "/tasks/done"), list: list).response.status == 405)
    check("405 POST /health", MainThingRouter.handle(request("POST", "/health"), list: list).response.status == 405)
    check("405 lowercase get", MainThingRouter.handle(request("get", "/tasks"), list: list).response.status == 405)
    check("405 does not change the list", del.changed == false && del.list == list)
}
do {
    let list = TaskList(["A"])
    let origin = MainThingRouter.handle(request("GET", "/health", headers: ["origin": "http://127.0.0.1:7788"]), list: list)
    check("Origin is refused even on /health", origin.response.status == 403)
    let originPut = MainThingRouter.handle(request("PUT", "/tasks", headers: ["origin": "null"], body: "[\"x\"]"), list: list)
    check("Origin PUT is refused and leaves the list", originPut.response.status == 403 && originPut.changed == false && originPut.list == list)
    check("missing Host is refused", MainThingRouter.handle(request("GET", "/health", host: nil), list: list).response.status == 403)
    check("foreign Host is refused", MainThingRouter.handle(request("GET", "/health", host: "evil.example"), list: list).response.status == 403)
    check("Host 127.0.0.1:7788", MainThingRouter.handle(request("GET", "/health", host: "127.0.0.1:7788"), list: list).response.status == 200)
    check("Host localhost:7788", MainThingRouter.handle(request("GET", "/health", host: "localhost:7788"), list: list).response.status == 200)
    check("Host [::1]:7788", MainThingRouter.handle(request("GET", "/health", host: "[::1]:7788"), list: list).response.status == 200)
    check("Host main-thing.localhost:7788", MainThingRouter.handle(request("GET", "/health", host: "main-thing.localhost:7788"), list: list).response.status == 200)
    check("Host main-thing.localhost without port", MainThingRouter.handle(request("GET", "/health", host: "Main-Thing.localhost"), list: list).response.status == 200)
    check("Host mainthing.localhost:7788, the old name until 0.4", MainThingRouter.handle(request("GET", "/health", host: "mainthing.localhost:7788"), list: list).response.status == 200)
    check("Host mainthing.localhost without port, the old name", MainThingRouter.handle(request("GET", "/health", host: "MainThing.localhost"), list: list).response.status == 200)
    check("Host main-thing.localhost lookalike is refused", MainThingRouter.handle(request("GET", "/health", host: "main-thing.localhost.evil.example"), list: list).response.status == 403)
    check("Host other.localhost is refused", MainThingRouter.handle(request("GET", "/health", host: "other.localhost:7788"), list: list).response.status == 403)
    check("Host without port", MainThingRouter.handle(request("GET", "/health", host: "localhost"), list: list).response.status == 200)
    check("Host [::1] without port", MainThingRouter.handle(request("GET", "/health", host: "[::1]"), list: list).response.status == 200)
    check("Host with port 80", MainThingRouter.handle(request("GET", "/health", host: "127.0.0.1:80"), list: list).response.status == 200)
    check("Host is case insensitive", MainThingRouter.handle(request("GET", "/health", host: "LOCALHOST:7788"), list: list).response.status == 200)
    check("Host lookalike is refused", MainThingRouter.handle(request("GET", "/health", host: "localhost.evil.example"), list: list).response.status == 403)
    check("hostWithoutPort strips a v6 port", MainThingRouter.hostWithoutPort("[::1]:7788") == "[::1]")
    check("hostWithoutPort strips a v4 port", MainThingRouter.hostWithoutPort("127.0.0.1:7788") == "127.0.0.1")
}

runHoverChecks()
runGeometryChecks()
runEventChecks()
runOpenChecks()
runCardChecks()
runUpdateChecks()
runPathChecks()
print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
