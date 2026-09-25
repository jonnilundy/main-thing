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

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("MainThing", isDirectory: true)
            .appendingPathComponent("tasks.json")
    }

    init(fileURL: URL = TaskStore.defaultFileURL, configDirectory: URL = EventRunner.defaultConfigDirectory) {
        TaskStore.copyLegacyFileIfNeeded(to: fileURL)
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
        self.runner = EventRunner(configDirectory: configDirectory) { job, record in
            MainActor.assumeIsolated { events.record(job, record) }
        }
    }

    /// First launch after the rename: copy NextUp's list when Main Thing has none. The old file stays.
    static func copyLegacyFileIfNeeded(to fileURL: URL) {
        let files = FileManager.default
        let legacy = fileURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(LegacyData.legacyDirectoryName, isDirectory: true)
            .appendingPathComponent(fileURL.lastPathComponent)
        guard LegacyData.shouldCopy(
            newExists: files.fileExists(atPath: fileURL.path),
            legacyExists: files.fileExists(atPath: legacy.path)
        ) else { return }
        let log = Logger(subsystem: MainThingBundleID, category: "store")
        do {
            try files.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: legacy, to: fileURL)
            log.notice("copied the NextUp list from \(legacy.path, privacy: .public)")
        } catch {
            log.error("could not copy the NextUp list from \(legacy.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    var current: String? { list.current }

    func replace(_ tasks: [TaskItem], source: String) {
        let before = list
        list.replace(tasks)
        save()
        emit(before: before, completed: nil, source: source)
    }

    /// Done from the notch, the API or the CLI. Removes the current task only when its title still matches.
    @discardableResult
    func complete(expected: String?, source: String) -> Bool {
        let before = list
        guard let removed = list.complete(expected: expected) else { return false }
        save()
        emit(before: before, completed: removed, source: source)
        return true
    }

    /// Routes one API request against the current list and runs the store method it asks for.
    /// `POST /tasks/done` and the done circle both end in `complete(expected:source:)`.
    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let outcome = MainThingRouter.handle(request, list: list, status: events.report(installed: runner.installed()))
        switch outcome.action {
        case .replace(let tasks, let source): replace(tasks, source: source)
        case .complete(let source): complete(expected: nil, source: source)
        case .none: break
        }
        return outcome.response
    }

    /// `task-completed` then `list-changed` after a completion, `list-changed` after any other change.
    private func emit(before: TaskList, completed: TaskItem?, source: String) {
        for payload in EventPlan.events(before: before, after: list, completed: completed, source: source, at: Date()) {
            runner.emit(payload)
        }
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
