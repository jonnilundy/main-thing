import Foundation
import MainThingCore

@MainActor
func runLinkChecks() {
    section("Links")
    check("a Linear issue URL is a link", LinkTask.url(in: "https://linear.app/acme/issue/ENG-123/fix-login") != nil)
    check("http is a link", LinkTask.url(in: "http://example.com") != nil)
    check("surrounding space is trimmed", LinkTask.url(in: "  https://example.com/a  \n") != nil)
    check("upper case scheme is a link", LinkTask.url(in: "HTTPS://Example.com/x") != nil)
    check("text around the URL is not a link", LinkTask.url(in: "read https://example.com") == nil)
    check("two URLs are not a link", LinkTask.url(in: "https://a.com https://b.com") == nil)
    check("a plain title is not a link", LinkTask.url(in: "Write the memo") == nil)
    check("ftp is not a link", LinkTask.url(in: "ftp://example.com/file") == nil)
    check("mailto is not a link", LinkTask.url(in: "mailto:me@example.com") == nil)
    check("no host is not a link", LinkTask.url(in: "https://") == nil && LinkTask.url(in: "https:///path") == nil)
    check("a bare domain is not a link", LinkTask.url(in: "example.com/path") == nil)
    check("blank is not a link", LinkTask.url(in: "   ") == nil)

    func placeholder(_ s: String) -> String { LinkTask.placeholder(for: LinkTask.url(in: s)!) }
    check("placeholder: host and last part", placeholder("https://linear.app/acme/issue/ENG-123/fix-login") == "linear.app/…/fix-login")
    check("placeholder: one part", placeholder("https://example.com/about") == "example.com/about")
    check("placeholder: no path is the host", placeholder("https://example.com") == "example.com")
    check("placeholder: trailing slash is ignored", placeholder("https://example.com/a/b/") == "example.com/…/b")
    check("placeholder: www goes, host lowercased", placeholder("https://WWW.Example.com/Page") == "example.com/Page")
    check("placeholder: query and fragment are dropped", placeholder("https://brain.example.com/task/abc123?x=1#y") == "brain.example.com/…/abc123")
    check("placeholder: percent encoding decoded", placeholder("https://example.com/a%20b") == "example.com/a b")
    let long = placeholder("https://example.com/" + String(repeating: "x", count: 80))
    check("placeholder: a long part is cut to the limit", long == "example.com/" + String(repeating: "x", count: 39) + "…")
    check("placeholder is not itself a link", LinkTask.url(in: placeholder("https://linear.app/acme/issue/ENG-1/x")) == nil)

    let at = Date(timeIntervalSince1970: 0)
    func reply(_ exit: Int32?, _ stdout: String, timedOut: Bool = false, stderr: String = "") -> ResolveOutcome {
        ResolveReply.outcome(adapter: "linear", record: RunRecord(at: at, exit: exit, ms: 5, timedOut: timedOut, stderr: stderr), stdout: Data(stdout.utf8))
    }
    check("exit 0 with id and title resolves", reply(0, #"{"id":"ENG-123","title":"Fix login"}"#) == .resolved(title: "Fix login", ref: "linear:ENG-123"))
    check("title and id are trimmed, newlines become spaces", reply(0, "{\"id\":\" ENG-1 \",\"title\":\" Fix\\nlogin \"}\n") == .resolved(title: "Fix login", ref: "linear:ENG-1"))
    check("extra fields are fine", reply(0, #"{"id":"a","title":"T","url":"x"}"#) == .resolved(title: "T", ref: "linear:a"))
    check("exit 3 is not mine", reply(3, "") == .notMine)
    check("exit 2, an unknown verb, is not mine", reply(2, "usage") == .notMine)
    check("exit 1 is a failure with stderr", reply(1, "", stderr: "no key") == .failed("exit 1: no key"))
    check("a timeout is a failure", reply(nil, "", timedOut: true) == .failed("no answer within 5 s"))
    check("exit 0 with no JSON is a failure", reply(0, "Fix login") == .failed("exit 0 but stdout is not one JSON object"))
    check("exit 0 with an array is a failure", reply(0, "[]") == .failed("exit 0 but stdout is not one JSON object"))
    check("no id is a failure", reply(0, #"{"title":"T"}"#) == .failed("reply has no \"id\" string"))
    check("a numeric id is a failure", reply(0, #"{"id":5,"title":"T"}"#) == .failed("reply has no \"id\" string"))
    check("no title is a failure", reply(0, #"{"id":"a"}"#) == .failed("reply has no \"title\" string"))
    check("a blank title is a failure", reply(0, #"{"id":"a","title":"  "}"#) == .failed("reply has an empty title"))
    if case .failed(let why) = reply(0, #"{"id":"a b","title":"T"}"#) {
        check("an id with a space makes a bad ref", why.hasPrefix("reply id makes a bad ref"))
    } else {
        check("an id with a space makes a bad ref", false)
    }

    let before = TaskList(["Write memo", "https://example.com/old"])
    var after = before
    after.replace([TaskItem("Write memo"), TaskItem("https://example.com/old"), TaskItem("https://linear.app/a/issue/ENG-1/x"),
                   TaskItem("Plain"), TaskItem("https://example.com/y", ref: "x:1")])
    check("new links: only new rows without a ref", after.newLinks(since: before) == [LinkRow(index: 2, url: "https://linear.app/a/issue/ENG-1/x")])
    check("new links: none when nothing was added", before.newLinks(since: before).isEmpty)
    var twice = TaskList(["https://a.com"])
    twice.replace(["https://a.com", "https://a.com"])
    check("new links: the second copy of a link is new", twice.newLinks(since: TaskList(["https://a.com"])) == [LinkRow(index: 1, url: "https://a.com")])
    check("new links: a link on an empty list", TaskList(["https://a.com/b"]).newLinks(since: TaskList()) == [LinkRow(index: 0, url: "https://a.com/b")])

    let pending = TaskList(["A", "linear.app/…/x", "B"])
    let key = pending.rows[1].key
    check("resolving retitles the row and sets the ref", pending.resolving(key: key, title: "Fix login", ref: "linear:ENG-1")
        == [TaskItem("A"), TaskItem("Fix login", ref: "linear:ENG-1"), TaskItem("B")])
    check("resolving a row that is gone is nil", pending.resolving(key: "gone#0", title: "T", ref: "linear:ENG-1") == nil)
    let taken = TaskList([TaskItem("Fix login", ref: "linear:ENG-1"), TaskItem("linear.app/…/x")])
    check("resolving to a ref already on the list is nil", taken.resolving(key: taken.rows[1].key, title: "Fix login", ref: "linear:ENG-1") == nil)
    var renamed = pending
    renamed.replace(pending.renaming(key: key, to: "My own title")!)
    check("a renamed row has a new key, so a late resolve misses it", renamed.resolving(key: key, title: "T", ref: "linear:ENG-1") == nil)

    let dir = URL(fileURLWithPath: "/c", isDirectory: true)
    let jobs = EventPlan.resolveJobs(url: "https://x.com", adapterNames: ["openbrain", "linear", "Bad Name", ".hidden", "a-1"], configDirectory: dir)
    check("resolve jobs: valid names, sorted", jobs.map(\.name) == ["a-1", "linear", "openbrain"])
    check("resolve jobs: path and arguments", jobs[1].path == "/c/adapters/linear" && jobs[1].arguments == ["resolve", "https://x.com"] && jobs[1].kind == .adapter)

    section("POST /tasks")
    let list = TaskList([TaskItem("A", ref: "x:1")])
    let add = MainThingRouter.handle(HTTPRequest(method: "POST", path: "/tasks", headers: ["host": "localhost"], body: Data(#"["B",{"title":"C","ref":"x:2"}]"#.utf8), query: ["source": "cli"]), list: list)
    check("POST /tasks appends", add.response.status == 200 && add.list.tasks == [TaskItem("A", ref: "x:1"), TaskItem("B"), TaskItem("C", ref: "x:2")])
    check("POST /tasks is a replace with the source", add.action == .replace([TaskItem("A", ref: "x:1"), TaskItem("B"), TaskItem("C", ref: "x:2")], source: "cli"))
    check("POST /tasks keeps the existing row's key", add.list.rows[0].key == list.rows[0].key)
    let dup = MainThingRouter.handle(request("POST", "/tasks", body: #"[{"title":"Z","ref":"x:1"}]"#), list: list)
    check("POST /tasks with a ref already on the list is 400", dup.response.status == 400 && text(dup.response) == #"{"error":"item 0: the ref x:1 is already on the list"}"# && !dup.changed)
    check("POST /tasks bad JSON is 400", MainThingRouter.handle(request("POST", "/tasks", body: "nope"), list: list).response.status == 400)
    check("POST /tasks bad source is 400", MainThingRouter.handle(HTTPRequest(method: "POST", path: "/tasks", headers: ["host": "localhost"], body: Data(#"["B"]"#.utf8), query: ["source": "Bad"]), list: list).response.status == 400)
}
