import Foundation
import NextUpCore

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
    check("version is 0.1.0", NextUpVersion == "0.1.0")
}
do {
    var list = TaskList(["M", "M", "X"])
    check("duplicate titles get different keys", list.rows.map(\.key) == ["M#0", "M#1", "X#0"])
    check("row id is the key", list.rows[1].id == "M#1")
    let before = Array(list.rows.dropFirst())
    check("complete(nil) removes index 0", list.complete(expected: nil) == true)
    check("remaining keys are unchanged after done", list.rows == before)
    check("remaining keys after done", list.rows.map(\.key) == ["M#1", "X#0"])
    check("complete with a stale title does nothing", list.complete(expected: "Not this") == false)
    check("list unchanged after stale done", list.rows.map(\.key) == ["M#1", "X#0"])
    check("complete with the matching title works", list.complete(expected: "M") == true)
    check("after matching done", list.rows.map(\.key) == ["X#0"])
    list.complete(expected: nil)
    check("complete on empty is a no op", list.complete(expected: nil) == false && list.isEmpty)
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
check("non-string item", BodyDecoding.tasks(from: Data("[\"A\",2]".utf8)) == .failure(BodyError("item 1 is not a string")))
check("object without tasks", BodyDecoding.tasks(from: Data("{\"x\":1}".utf8)) == .failure(BodyError("object needs a \"tasks\" array")))
check("top level string", BodyDecoding.tasks(from: Data("\"A\"".utf8)).isFailure)
check("empty body", BodyDecoding.tasks(from: Data()) == .failure(BodyError("empty body, send a JSON array of strings")))

extension Result { var isFailure: Bool { if case .failure = self { true } else { false } } }

// MARK: Routing and guards

section("NextUpRouter")
do {
    let list = TaskList(["A", "B"])
    let out = NextUpRouter.handle(request("GET", "/tasks"), list: list)
    check("GET /tasks", out.response.status == 200 && text(out.response) == "{\"tasks\":[\"A\",\"B\"]}" && out.changed == false)
    let slash = NextUpRouter.handle(request("GET", "/tasks/"), list: list)
    check("trailing slash is tolerated", slash.response.status == 200)
}
do {
    let list = TaskList(["A"])
    let out = NextUpRouter.handle(request("PUT", "/tasks", body: "[\" X \", \"\", \"Y\"]"), list: list)
    check("PUT array replaces, trims, drops blanks", out.response.status == 200 && text(out.response) == "{\"tasks\":[\"X\",\"Y\"]}")
    check("PUT reports changed", out.changed && out.list.titles == ["X", "Y"])
    let obj = NextUpRouter.handle(request("PUT", "/tasks", body: "{\"tasks\":[\"Z\"]}"), list: list)
    check("PUT object form", obj.list.titles == ["Z"])
    let bad = NextUpRouter.handle(request("PUT", "/tasks", body: "{oops"), list: list)
    check("PUT bad JSON is 400 with a reason", bad.response.status == 400 && text(bad.response) == "{\"error\":\"body is not valid JSON\"}" && bad.changed == false)
    check("PUT bad JSON leaves the list", bad.list == list)
}
do {
    let list = TaskList(["A", "B"])
    let out = NextUpRouter.handle(request("POST", "/tasks/done"), list: list)
    check("POST /tasks/done removes index 0", text(out.response) == "{\"tasks\":[\"B\"]}" && out.changed && out.list.titles == ["B"])
    let empty = NextUpRouter.handle(request("POST", "/tasks/done"), list: TaskList())
    check("POST /tasks/done on empty is 200 and unchanged", empty.response.status == 200 && text(empty.response) == "{\"tasks\":[]}" && empty.changed == false)
}
do {
    let out = NextUpRouter.handle(request("GET", "/health"), list: TaskList())
    check("GET /health exact body", out.response.status == 200 && text(out.response) == "{\"ok\":true,\"version\":\"0.1.0\"}")
    let wire = String(decoding: out.response.serialized(), as: UTF8.self)
    check("serialized status line", wire.hasPrefix("HTTP/1.1 200 OK\r\n"))
    check("serialized content length", wire.contains("\r\nContent-Length: 29\r\n"))
    check("serialized closes the connection", wire.contains("\r\nConnection: close\r\n"))
    check("serialized body after blank line", wire.hasSuffix("\r\n\r\n{\"ok\":true,\"version\":\"0.1.0\"}"))
}
do {
    let list = TaskList(["A"])
    check("404 unknown route", NextUpRouter.handle(request("GET", "/nope"), list: list).response.status == 404)
    let del = NextUpRouter.handle(request("DELETE", "/tasks"), list: list)
    check("405 DELETE /tasks", del.response.status == 405 && del.response.headers["Allow"] == "GET, PUT")
    check("405 GET /tasks/done", NextUpRouter.handle(request("GET", "/tasks/done"), list: list).response.status == 405)
    check("405 POST /health", NextUpRouter.handle(request("POST", "/health"), list: list).response.status == 405)
    check("405 lowercase get", NextUpRouter.handle(request("get", "/tasks"), list: list).response.status == 405)
    check("405 does not change the list", del.changed == false && del.list == list)
}
do {
    let list = TaskList(["A"])
    let origin = NextUpRouter.handle(request("GET", "/health", headers: ["origin": "http://127.0.0.1:7788"]), list: list)
    check("Origin is refused even on /health", origin.response.status == 403)
    let originPut = NextUpRouter.handle(request("PUT", "/tasks", headers: ["origin": "null"], body: "[\"x\"]"), list: list)
    check("Origin PUT is refused and leaves the list", originPut.response.status == 403 && originPut.changed == false && originPut.list == list)
    check("missing Host is refused", NextUpRouter.handle(request("GET", "/health", host: nil), list: list).response.status == 403)
    check("foreign Host is refused", NextUpRouter.handle(request("GET", "/health", host: "evil.example"), list: list).response.status == 403)
    check("Host 127.0.0.1:7788", NextUpRouter.handle(request("GET", "/health", host: "127.0.0.1:7788"), list: list).response.status == 200)
    check("Host localhost:7788", NextUpRouter.handle(request("GET", "/health", host: "localhost:7788"), list: list).response.status == 200)
    check("Host [::1]:7788", NextUpRouter.handle(request("GET", "/health", host: "[::1]:7788"), list: list).response.status == 200)
    check("Host without port", NextUpRouter.handle(request("GET", "/health", host: "localhost"), list: list).response.status == 200)
    check("Host is case insensitive", NextUpRouter.handle(request("GET", "/health", host: "LOCALHOST:7788"), list: list).response.status == 200)
    check("Host lookalike is refused", NextUpRouter.handle(request("GET", "/health", host: "localhost.evil.example"), list: list).response.status == 403)
    check("hostWithoutPort strips a v6 port", NextUpRouter.hostWithoutPort("[::1]:7788") == "[::1]")
    check("hostWithoutPort strips a v4 port", NextUpRouter.hostWithoutPort("127.0.0.1:7788") == "127.0.0.1")
}

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
