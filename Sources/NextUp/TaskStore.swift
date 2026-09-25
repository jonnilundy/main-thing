import Foundation
import NextUpCore
import Observation
import os

/// The one writer of the task list. The API and the UI both go through here.
/// Saves `[String]` atomically to `~/Library/Application Support/NextUp/tasks.json`.
@Observable
@MainActor
final class TaskStore {
    private(set) var list: TaskList

    @ObservationIgnored let fileURL: URL
    @ObservationIgnored private let log = Logger(subsystem: NextUpBundleID, category: "store")

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("NextUp", isDirectory: true)
            .appendingPathComponent("tasks.json")
    }

    init(fileURL: URL = TaskStore.defaultFileURL) {
        self.fileURL = fileURL
        var loaded = TaskList()
        var loadError: String?
        if let data = try? Data(contentsOf: fileURL) {
            do {
                loaded = TaskList(try JSONDecoder().decode([String].self, from: data))
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
    }

    var current: String? { list.current }

    func replace(_ titles: [String]) {
        list.replace(titles)
        save()
    }

    /// Done from the UI. Removes the current task only when its title still matches.
    @discardableResult
    func complete(expected: String?) -> Bool {
        let changed = list.complete(expected: expected)
        if changed { save() }
        return changed
    }

    /// Routes one API request against the current list and adopts the result.
    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let outcome = NextUpRouter.handle(request, list: list)
        if outcome.changed {
            list = outcome.list
            save()
        }
        return outcome.response
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(list.titles)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("save failed at \(self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
