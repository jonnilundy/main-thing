import AppKit
import Foundation
import MainThingCore
import Observation
import os

/// The one writer of the task list. The API and the UI both go through here.
/// Saves `[{"title":...,"ref":...}]` atomically to `~/Library/Application Support/MainThing/tasks.json`.
/// A file written before refs existed, a plain `[String]`, still loads.
@Observable
@MainActor
final class TaskStore {
    private(set) var list: TaskList

    @ObservationIgnored let fileURL: URL
    @ObservationIgnored private let log = Logger(subsystem: MainThingBundleID, category: "store")
    /// Hooks and adapters. Every change goes out as events after it is saved.
    @ObservationIgnored private(set) var runner: EventRunner!
    let events = EventStatus()
    /// Called on the main actor right after the list changed and was saved, before events go out.
    /// The panel uses it to size itself before the shape animates.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    /// Rows added as one link that wait for their title, by row key. The rows draw dim meanwhile.
    private(set) var resolving: [String: PendingLink] = [:]
    /// Asks the adapters about a new link. Nil in previews and probes: a link there stays as typed.
    @ObservationIgnored private var resolver: LinkResolver?
    @ObservationIgnored private var linkToken = 0
    /// True while the row with this key is being renamed: a late title never lands under the user.
    @ObservationIgnored var isEditing: (@MainActor (String) -> Bool)?
    /// A resolved link gets a ref, so its row key changes from the title's to the ref's. Called
    /// with the old and the new key right before the change lands.
    @ObservationIgnored var willRekey: (@MainActor (String, String) -> Void)?

    /// Cross offs and discards from the card while they can come back, newest last. A cross off's
    /// task-completed event (its done hook and adapter) waits here until its window ends.
    private(set) var undo = UndoStack()
    /// The clock for the Undo windows.
    @ObservationIgnored var now: () -> TimeInterval = { Date.timeIntervalSinceReferenceDate }
    /// Called at quit before the held cross offs commit, so the pen strokes still drawing join them.
    @ObservationIgnored var beforeQuit: (@MainActor () -> Void)?
    /// Every event as it goes to the runner, and every one committed at quit. The probe reads them.
    @ObservationIgnored var onEmit: (@MainActor (EventPayload) -> Void)?
    @ObservationIgnored private var undoTimer: Task<Void, Never>?
    @ObservationIgnored private var quitObserver: (any NSObjectProtocol)?

    struct PendingLink: Equatable {
        let url: String
        let token: Int
    }

    /// The real list for the release app, a list keyed by bundle id for a test copy (`AppPaths`).
    /// `MAIN_THING_TASKS_FILE` in the environment points a test copy at its own file.
    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return AppPaths.tasksFile(environment: ProcessInfo.processInfo.environment, bundleID: Bundle.main.bundleIdentifier, applicationSupport: base)
    }

    init(fileURL: URL = TaskStore.defaultFileURL, configDirectory: URL = EventRunner.defaultConfigDirectory, adapters: AdapterSettings? = nil) {
        self.fileURL = fileURL
        var loaded = TaskList()
        var loadError: String?
        if let data = try? Data(contentsOf: fileURL) {
            do {
                loaded = TaskList(try JSONDecoder().decode([TaskItem].self, from: data))
            } catch {
                loadError = error.localizedDescription
            }
        }
        self.list = loaded
        if let loadError {
            // The file stays as it is so it can be fixed by hand. The next PUT overwrites it.
            log.error("could not read \(fileURL.path, privacy: .public): \(loadError, privacy: .public)")
        } else {
            log.info("loaded \(loaded.count, privacy: .public) tasks from \(fileURL.path, privacy: .public)")
        }
        let events = self.events
        self.runner = EventRunner(configDirectory: configDirectory, adapters: adapters) { job, record in
            MainActor.assumeIsolated { events.record(job, record) }
        }
        self.resolver = LinkResolver(configDirectory: configDirectory, adapters: adapters)
        // Quitting ends every Undo window: the held cross offs commit before the app exits.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitBeforeQuit() }
        }
    }

    /// Previews: the list in memory. Reads and writes no file, and runs no hook or adapter.
    init(previewTitles titles: [String]) {
        fileURL = URL(fileURLWithPath: "/dev/null")
        list = TaskList(titles)
        runner = EventRunner(configDirectory: URL(fileURLWithPath: "/var/empty")) { _, _ in }
    }

    var current: String? { list.current }

    /// Every edit lands here. A new task that is exactly one link shows a placeholder at once, and
    /// the adapters are asked for its title (`holdLinks`).
    func replace(_ tasks: [TaskItem], source: String) {
        apply(tasks, source: source, links: true)
    }

    private func apply(_ tasks: [TaskItem], source: String, links: Bool) {
        let before = list
        list.replace(tasks)
        if links { holdLinks(since: before) }
        save()
        emit(before: before, completed: nil, source: source)
    }

    /// New rows that are one link get the placeholder title (`LinkTask.placeholder`) and go to the
    /// resolver. The answer lands by row key, so an edit or a removal meanwhile wins.
    private func holdLinks(since before: TaskList) {
        guard let resolver else { return }
        let links = list.newLinks(since: before)
        guard !links.isEmpty else { return }
        var tasks = list.tasks
        for link in links {
            if let url = LinkTask.url(in: link.url) { tasks[link.index].title = LinkTask.placeholder(for: url) }
        }
        list.replace(tasks)
        for link in links {
            let key = list.rows[link.index].key
            linkToken += 1
            let token = linkToken
            resolving[key] = PendingLink(url: link.url, token: token)
            log.notice("row \(link.index + 1, privacy: .public) is a link: asking the adapters")
            resolver.resolve(link.url) { [weak self] result in
                self?.finishLink(key: key, token: token, result)
            }
        }
    }

    private func finishLink(key: String, token: Int, _ result: LinkResolver.Result) {
        guard let pending = resolving[key], pending.token == token else {
            log.notice("link answer dropped: the row was added again since")
            return
        }
        resolving[key] = nil
        guard list.rows.contains(where: { $0.key == key }) else {
            log.notice("link answer dropped: the task was edited or removed meanwhile")
            return
        }
        if isEditing?(key) == true {
            log.notice("link answer dropped: the task is being renamed")
            return
        }
        switch result {
        case .resolved(let title, let ref, let adapter):
            if let tasks = list.resolving(key: key, title: title, ref: ref) {
                willRekey?(key, "ref:\(ref)")
                apply(tasks, source: "resolve", links: false)
                log.notice("link resolved by \(adapter, privacy: .public) as \(ref, privacy: .public)")
            } else {
                keepURL(key: key, pending.url)
                log.notice("link kept as typed: \(ref, privacy: .public) is already on the list")
            }
        case .unclaimed(let why):
            keepURL(key: key, pending.url)
            log.notice("link kept as typed: \(why, privacy: .public)")
        }
    }

    /// The link goes back as the title, as it was typed.
    private func keepURL(key: String, _ url: String) {
        if let tasks = list.renaming(key: key, to: url) { apply(tasks, source: "resolve", links: false) }
    }

    /// Done from the notch, the API or the CLI. Removes the current task only when its title still matches.
    @discardableResult
    func complete(expected: String?, source: String) -> Bool {
        guard let key = list.rows.first?.key else { return false }
        return complete(key: key, expected: expected, source: source)
    }

    /// Done for any row, by its key. `expected` guards against a stale click on a row that changed.
    @discardableResult
    func complete(key: String, expected: String?, source: String) -> Bool {
        let before = list
        guard let removed = list.complete(key: key, expected: expected) else { return false }
        save()
        emit(before: before, completed: removed, source: source)
        return true
    }

    // MARK: Undo

    /// A cross off from the card or a shortcut. The row leaves now and `list-changed` goes out, but
    /// `task-completed` (the done hook, the adapter) waits until the Undo window ends, so an undo
    /// never has to reopen anything elsewhere. The API and the CLI use `complete`: at once.
    @discardableResult
    func completeHeld(key: String, expected: String?, source: String) -> Discarded? {
        guard let row = list.rows.first(where: { $0.key == key }), expected == nil || expected == row.title,
              let (tasks, gone) = list.discarding(key: key, at: now(), kind: .done) else { return nil }
        hold(gone, leaving: tasks, source: source)
        log.notice("crossed off row \(gone.index + 1, privacy: .public): done waits \(Int(Discarded.seconds), privacy: .public)s for an undo")
        return gone
    }

    /// A discard from the card: the row leaves, `list-changed` goes out, and no done hook or
    /// adapter ever runs for it.
    @discardableResult
    func discard(key: String, source: String) -> Discarded? {
        guard let (tasks, gone) = list.discarding(key: key, at: now(), kind: .discard) else { return nil }
        hold(gone, leaving: tasks, source: source)
        log.notice("discarded row \(gone.index + 1, privacy: .public)")
        return gone
    }

    private func hold(_ gone: Discarded, leaving tasks: [TaskItem], source: String) {
        undo.push(gone)
        scheduleUndo()
        apply(tasks, source: source, links: false)
    }

    /// Undo: the newest cross off or discard still in its window comes back to its old place, with
    /// its ref. A cross off undone never sends its task-completed.
    @discardableResult
    func undoLast(source: String = EventSource.notch) -> Discarded? {
        guard let gone = undo.undo(at: now()) else { return nil }
        scheduleUndo()
        apply(gone.restored(into: list.tasks), source: source, links: false)
        log.notice("undo: row \(gone.index + 1, privacy: .public) back, \(gone.kind.rawValue, privacy: .public) not sent")
        return gone
    }

    /// One timer for the window that ends first.
    private func scheduleUndo() {
        undoTimer?.cancel()
        undoTimer = nil
        guard let next = undo.nextExpiry else { return }
        let wait = max(next - now(), 0) + 0.02
        undoTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.expireUndo()
        }
    }

    /// Windows ended: the cross offs among them commit, the discards are just gone.
    private func expireUndo() {
        let ended = undo.expire(at: now())
        scheduleUndo()
        for entry in ended {
            guard let payload = EventPlan.commit(entry, list: list, source: EventSource.notch, at: Date()) else { continue }
            log.notice("cross off committed: the undo window ended")
            send(payload)
        }
    }

    /// The app quits: every Undo window ends now. The held cross offs commit, and their adapters
    /// and done hooks run here, on the main thread, before the app exits: the event queue would
    /// not get to them. The same plan, permission check and runner the queue uses.
    func commitBeforeQuit() {
        beforeQuit?()
        undoTimer?.cancel()
        undoTimer = nil
        let payloads = undo.drain().compactMap { EventPlan.commit($0, list: list, source: EventSource.notch, at: Date()) }
        guard !payloads.isEmpty else { return }
        log.notice("quit: \(payloads.count, privacy: .public) held cross offs commit now")
        let lookup = runner.adapters?.lookup() ?? .folderOnly
        for payload in payloads {
            onEmit?(payload)
            let data = payload.encoded()
            let jobs = EventPlan.jobs(for: payload, configDirectory: runner.configDirectory, lookup: lookup) { FileManager.default.fileExists(atPath: $0) }
            for job in jobs {
                if let problem = RunPermission.problem(EventRunner.facts(of: job.path), currentUID: getuid(), allowRoot: job.builtIn) {
                    log.error("quit: skip \(job.kind.rawValue, privacy: .public) \(job.name, privacy: .public): \(problem, privacy: .public)")
                    continue
                }
                let environment = job.builtIn ? runner.adapters?.processEnvironment(for: job.name) : nil
                let record = EventRunner.execute(path: job.path, arguments: job.arguments, stdin: data, timeout: EventRunner.timeout, environment: environment).record
                events.record(job, record)
                log.notice("quit: \(job.kind.rawValue, privacy: .public) \(job.name, privacy: .public) for task-completed: exit \(record.exit.map(String.init) ?? "signal", privacy: .public) in \(record.ms, privacy: .public) ms")
            }
        }
    }

    /// Routes one API request against the current list and runs the store method it asks for.
    /// `POST /tasks/done` and the done circle both end in `complete(expected:source:)`.
    func handle(_ request: HTTPRequest, port: UInt16) -> HTTPResponse {
        let outcome = MainThingRouter.handle(request, list: list, status: events.report(installed: runner.installed()), port: port)
        switch outcome.action {
        case .replace(let tasks, let source): replace(tasks, source: source)
        case .complete(let key, let source): complete(key: key, expected: nil, source: source)
        case .none: break
        }
        // A change answers with the list as the store has it, placeholders for new links included.
        return outcome.changed ? .json(200, JSONBody.tasks(list)) : outcome.response
    }

    /// `task-completed` then `list-changed` after a completion, `list-changed` after any other change.
    private func emit(before: TaskList, completed: TaskItem?, source: String) {
        onChange?()
        for payload in EventPlan.events(before: before, after: list, completed: completed, source: source, at: Date()) {
            send(payload)
        }
    }

    private func send(_ payload: EventPayload) {
        onEmit?(payload)
        runner.emit(payload)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = JSONBody.encode(list.tasks)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("save failed at \(self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
