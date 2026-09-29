import Foundation

/// A task added as one link: `https://linear.app/acme/issue/ENG-123/fix-login`. The app shows a
/// short placeholder at once and asks the installed adapters, `<adapter> resolve <url>`, for the
/// real title and the id. The first adapter that claims the link wins.
public enum LinkTask {
    /// The link when `text` is exactly one http or https URL with a host, else nil.
    public static func url(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        guard let components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty,
              let url = components.url else { return nil }
        return url
    }

    public static let placeholderPartLimit = 40

    /// What the task shows while the adapters look: the host without `www.`, then the last path
    /// part. `linear.app/…/fix-login`, `example.com/about`, or just `example.com`.
    public static func placeholder(for url: URL) -> String {
        var host = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.host ?? url.absoluteString).lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let parts = url.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }.filter { !$0.isEmpty }
        guard var last = parts.last else { return host }
        if last.count > placeholderPartLimit { last = String(last.prefix(placeholderPartLimit - 1)) + "…" }
        return parts.count == 1 ? "\(host)/\(last)" : "\(host)/…/\(last)"
    }
}

/// What one `<adapter> resolve <url>` run said.
public enum ResolveOutcome: Equatable, Sendable {
    /// The link is this adapter's: the task's new title and ref.
    case resolved(title: String, ref: String)
    /// Exit 3 (not mine) or 2 (the adapter does not know `resolve`).
    case notMine
    /// Anything else, with why.
    case failed(String)
}

/// The contract of the `resolve` verb, pure. Exit 0 with one JSON object `{"id":"...","title":"..."}`
/// on stdout claims the link. Exit 3 means not mine, and exit 2, an unknown verb, counts the same.
public enum ResolveReply {
    public static let notMineExit: Int32 = 3
    public static let unknownVerbExit: Int32 = 2
    /// Each adapter gets this long to answer.
    public static let timeout: TimeInterval = 5

    public static func outcome(adapter: String, record: RunRecord, stdout: Data) -> ResolveOutcome {
        if record.timedOut { return .failed("no answer within \(Int(timeout)) s") }
        guard let exit = record.exit else { return .failed(record.stderr.isEmpty ? "killed by a signal" : record.stderr) }
        if exit == notMineExit || exit == unknownVerbExit { return .notMine }
        guard exit == 0 else { return .failed("exit \(exit)" + (record.stderr.isEmpty ? "" : ": " + record.stderr)) }
        guard let object = try? JSONSerialization.jsonObject(with: stdout), let dict = object as? [String: Any] else {
            return .failed("exit 0 but stdout is not one JSON object")
        }
        guard let rawID = dict["id"] as? String else { return .failed("reply has no \"id\" string") }
        guard let rawTitle = dict["title"] as? String else { return .failed("reply has no \"title\" string") }
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .failed("reply has an empty title") }
        let ref = "\(adapter):\(id)"
        if let problem = TaskRef.problem(ref) { return .failed("reply id makes a bad ref: \(problem)") }
        return .resolved(title: title, ref: ref)
    }
}

/// A row that was added as one link and waits for its title.
public struct LinkRow: Equatable, Sendable {
    public var index: Int
    public var url: String

    public init(index: Int, url: String) {
        self.index = index
        self.url = url
    }
}

extension TaskList {
    /// Rows that are new since `before` (their key was not there), have no ref, and whose title is
    /// exactly one link. A link that was already on the list, say one no adapter claimed, is not new.
    public func newLinks(since before: TaskList) -> [LinkRow] {
        let old = Set(before.rows.map(\.key))
        return rows.enumerated().compactMap { index, row in
            guard row.ref == nil, !old.contains(row.key), LinkTask.url(in: row.title) != nil else { return nil }
            return LinkRow(index: index, url: row.title)
        }
    }

    /// The list with the row `key` retitled and given `ref`. Nil when the row is gone, or when
    /// another task already has that ref.
    public func resolving(key: String, title: String, ref: String) -> [TaskItem]? {
        guard let i = rows.firstIndex(where: { $0.key == key }), !rows.contains(where: { $0.ref == ref }) else { return nil }
        var result = tasks
        result[i] = TaskItem(title, ref: ref)
        return result
    }
}

extension EventPlan {
    /// The adapters to ask about a link, in name order (`AdapterLookup.resolveNames`), each called
    /// as `<name> resolve <url>`: valid names in `adapters/` that are not built-in, and the
    /// enabled built-ins from the app bundle.
    public static func resolveJobs(url: String, adapterNames: [String], configDirectory: URL, lookup: AdapterLookup = .folderOnly) -> [EventJob] {
        lookup.resolveNames(folderNames: adapterNames).map { name in
            if let path = lookup.enabledBuiltIns[name] {
                return EventJob(kind: .adapter, name: name, path: path, arguments: ["resolve", url], builtIn: true)
            }
            return EventJob(kind: .adapter, name: name, path: adaptersDirectory(configDirectory).appendingPathComponent(name).path,
                            arguments: ["resolve", url])
        }
    }
}
