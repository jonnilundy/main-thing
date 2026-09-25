import Foundation

/// A parsed HTTP/1.x request. Header names are lowercased. `path` has no query; `query` holds it, decoded.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
    public var query: [String: String]

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data(), query: [String: String] = [:]) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.query = query
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// `a=1&b=x%20y` -> `["a": "1", "b": "x y"]`. A key without `=` maps to "". The last repeat wins.
    public static func parseQuery(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1 ? (String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[1])) : ""
            out[key] = value
        }
        return out
    }
}

/// A response. Always JSON, always `Connection: close`.
public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ status: Int, _ body: Data, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: body)
    }

    /// `{"error":"<reason>"}` with the given status.
    public static func error(_ status: Int, _ reason: String, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: JSONBody.error(reason))
    }

    public var bodyText: String { String(decoding: body, as: UTF8.self) }

    public static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Content Too Large"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        default: "Status \(status)"
        }
    }

    /// Wire bytes: status line, headers, blank line, body.
    public func serialized() -> Data {
        var lines = [
            "HTTP/1.1 \(status) \(HTTPResponse.reasonPhrase(status))",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Connection: close",
        ]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }
}

/// Response bodies. Keys are sorted so the output is the same on every run and every Foundation:
/// a task is `{"ref":...,"title":...}` with the ref left out when there is none.
public enum JSONBody {
    private struct Tasks: Encodable { let tasks: [TaskItem] }
    private struct Health: Encodable { let ok: Bool; let version: String }
    private struct Failure: Encodable { let error: String }

    public static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding plain strings and bools cannot fail.
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    public static func tasks(_ list: TaskList) -> Data { encode(Tasks(tasks: list.tasks)) }
    public static func status(_ report: StatusReport) -> Data { encode(report) }
    public static func health() -> Data { encode(Health(ok: true, version: MainThingVersion)) }
    public static func error(_ reason: String) -> Data { encode(Failure(error: reason)) }
}

/// Incremental HTTP/1.x request parser. Feed it bytes as they arrive.
/// Bodies are read by `Content-Length`. Over 64 KB is refused before the body arrives.
public struct HTTPRequestParser: Sendable {
    public static let maxBodyBytes = 65_536
    public static let maxHeadBytes = 16_384

    public enum Step: Equatable, Sendable {
        case needMore
        case request(HTTPRequest)
        case failure(HTTPResponse)
    }

    private struct Head: Sendable {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var contentLength: Int
    }

    private enum HeadResult {
        case incomplete
        case head(Head)
        case failure(HTTPResponse)
    }

    private var buffer = Data()
    private var head: Head?

    public init() {}

    public mutating func feed(_ data: Data) -> Step {
        buffer.append(data)

        if head == nil {
            switch parseHead() {
            case .incomplete: return .needMore
            case .failure(let response): return .failure(response)
            case .head(let parsed): head = parsed
            }
        }
        guard let head else { return .needMore }
        guard buffer.count >= head.contentLength else { return .needMore }

        let body = Data(buffer.prefix(head.contentLength))
        buffer = Data(buffer.dropFirst(head.contentLength))
        self.head = nil
        return .request(HTTPRequest(method: head.method, path: head.path, headers: head.headers, body: body, query: head.query))
    }

    private mutating func parseHead() -> HeadResult {
        let terminator = Data("\r\n\r\n".utf8)
        guard let separator = buffer.range(of: terminator) else {
            if buffer.count > HTTPRequestParser.maxHeadBytes {
                return .failure(.error(431, "request head over 16 KB"))
            }
            return .incomplete
        }
        let headData = buffer.subdata(in: buffer.startIndex..<separator.lowerBound)
        guard let text = String(data: headData, encoding: .utf8) else {
            return .failure(.error(400, "request head is not UTF-8"))
        }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/") else {
            return .failure(.error(400, "malformed request line"))
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .failure(.error(400, "malformed header line"))
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        if headers["transfer-encoding"] != nil {
            return .failure(.error(400, "chunked bodies are not supported, send Content-Length"))
        }
        var contentLength = 0
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else {
                return .failure(.error(400, "bad Content-Length"))
            }
            contentLength = n
        }
        if contentLength > HTTPRequestParser.maxBodyBytes {
            return .failure(.error(413, "body over 64 KB"))
        }

        let target = String(parts[1])
        let split = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = split.first.map(String.init) ?? target
        let query = split.count > 1 ? HTTPRequest.parseQuery(String(split[1])) : [:]

        buffer = Data(buffer[separator.upperBound...])
        return .head(Head(method: String(parts[0]), path: path, query: query, headers: headers, contentLength: contentLength))
    }
}
