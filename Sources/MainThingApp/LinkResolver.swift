import Darwin
import Foundation
import MainThingCore
import os

/// Asks the installed adapters what a link is: `<adapter> resolve <url>`, in name order, 5 seconds
/// each, until one claims it. Off the main thread, one link at a time. Only the log records these
/// runs: an adapter that says "not mine" is not failing, so `main-thing adapters` and the
/// "sync failed" line stay about `complete`. The link and the title are logged as private data.
final class LinkResolver: @unchecked Sendable {
    enum Result: Sendable, Equatable {
        case resolved(title: String, ref: String, adapter: String)
        /// No adapter claimed it, with why.
        case unclaimed(String)
    }

    let configDirectory: URL
    private let queue = DispatchQueue(label: MainThingBundleID + ".resolve", qos: .userInitiated)
    private let log = Logger(subsystem: MainThingBundleID, category: "resolve")

    init(configDirectory: URL) {
        self.configDirectory = configDirectory
    }

    /// `completion` runs on the main actor.
    func resolve(_ url: String, completion: @escaping @MainActor @Sendable (Result) -> Void) {
        queue.async { [self] in
            let result = lookUp(url)
            Task { @MainActor in completion(result) }
        }
    }

    private func lookUp(_ url: String) -> Result {
        let directory = EventPlan.adaptersDirectory(configDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let jobs = EventPlan.resolveJobs(url: url, adapterNames: names, configDirectory: configDirectory)
        guard !jobs.isEmpty else { return .unclaimed("no adapters installed") }
        var problems: [String] = []
        for job in jobs {
            if let problem = RunPermission.problem(EventRunner.facts(of: job.path), currentUID: getuid()) {
                log.error("skip adapter \(job.name, privacy: .public) for resolve: \(problem, privacy: .public)")
                problems.append("\(job.name) skipped")
                continue
            }
            let (record, stdout) = EventRunner.execute(path: job.path, arguments: job.arguments, stdin: Data(), timeout: ResolveReply.timeout)
            switch ResolveReply.outcome(adapter: job.name, record: record, stdout: stdout) {
            case .resolved(let title, let ref):
                log.notice("resolve \(url, privacy: .private): \(job.name, privacy: .public) claimed it in \(record.ms, privacy: .public) ms as \(ref, privacy: .public)")
                return .resolved(title: title, ref: ref, adapter: job.name)
            case .notMine:
                log.info("resolve: \(job.name, privacy: .public) says not mine (exit \(record.exit ?? -1, privacy: .public)) in \(record.ms, privacy: .public) ms")
            case .failed(let why):
                log.error("resolve \(url, privacy: .private): \(job.name, privacy: .public) failed in \(record.ms, privacy: .public) ms: \(why, privacy: .private)")
                problems.append("\(job.name) failed")
            }
        }
        return .unclaimed(problems.isEmpty ? "no adapter claims it" : "no adapter claimed it (" + problems.joined(separator: ", ") + ")")
    }
}
