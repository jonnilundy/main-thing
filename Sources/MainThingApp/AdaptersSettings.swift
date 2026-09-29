import AppKit
import MainThingCore
import Observation
import SwiftUI

/// What the Adapters tab shows and changes. Enable and plain values go to UserDefaults, secrets
/// to the Keychain, through `AdapterSettings`. The view never sees a stored secret, only whether
/// one exists.
@Observable
@MainActor
final class AdaptersModel {
    @ObservationIgnored let settings: AdapterSettings
    @ObservationIgnored private weak var store: TaskStore?

    private(set) var enabled: [String: Bool] = [:]
    private(set) var plain: [String: String] = [:]
    private(set) var stored: [String: Bool] = [:]
    private(set) var envFiles: [String: Bool] = [:]
    private(set) var custom: [InstalledEntry] = []
    private(set) var checking: Set<String> = []
    private(set) var results: [String: AdapterCheck.Outcome] = [:]
    /// A Keychain write that failed, by field.
    private(set) var saveErrors: [String: String] = [:]
    /// Previews: last runs to show without a store.
    @ObservationIgnored var previewRuns: [String: RunRecord] = [:]

    init(settings: AdapterSettings, store: TaskStore?) {
        self.settings = settings
        self.store = store
        refresh()
    }

    private static func key(_ adapter: BuiltInAdapter, _ field: AdapterField) -> String { adapter.name + "/" + field.envName }

    /// Reads everything again: after launch, when the tab shows, when the app comes forward.
    func refresh() {
        for adapter in BuiltInAdapters.all {
            enabled[adapter.name] = settings.isEnabled(adapter.name)
            envFiles[adapter.name] = settings.envFileExists(adapter)
            for field in adapter.fields {
                if field.secret {
                    stored[Self.key(adapter, field)] = settings.hasSecret(adapter, field)
                } else {
                    plain[Self.key(adapter, field)] = settings.plainValue(adapter, field)
                }
            }
        }
        if let store {
            custom = store.runner.installed().adapters.filter { $0.builtIn != true }
        }
    }

    func isEnabled(_ adapter: BuiltInAdapter) -> Bool { enabled[adapter.name] ?? false }

    func setEnabled(_ adapter: BuiltInAdapter, _ on: Bool) {
        settings.setEnabled(adapter.name, on)
        enabled[adapter.name] = on
        refreshCustom()
    }

    func plainValue(_ adapter: BuiltInAdapter, _ field: AdapterField) -> String { plain[Self.key(adapter, field)] ?? "" }

    func setPlainValue(_ value: String, _ adapter: BuiltInAdapter, _ field: AdapterField) {
        plain[Self.key(adapter, field)] = value
        settings.setPlainValue(value, adapter, field)
        results[adapter.name] = nil
    }

    func hasSecret(_ adapter: BuiltInAdapter, _ field: AdapterField) -> Bool { stored[Self.key(adapter, field)] ?? false }

    func saveError(_ adapter: BuiltInAdapter, _ field: AdapterField) -> String? { saveErrors[Self.key(adapter, field)] }

    /// Returns true when saved.
    @discardableResult
    func saveSecret(_ value: String, _ adapter: BuiltInAdapter, _ field: AdapterField) -> Bool {
        let key = Self.key(adapter, field)
        do {
            try settings.setSecret(value, adapter, field)
            saveErrors[key] = nil
            stored[key] = settings.hasSecret(adapter, field)
            results[adapter.name] = nil
            return true
        } catch {
            saveErrors[key] = "Could not save to the Keychain: \(error)"
            return false
        }
    }

    func removeSecret(_ adapter: BuiltInAdapter, _ field: AdapterField) {
        let key = Self.key(adapter, field)
        do {
            try settings.removeSecret(adapter, field)
            saveErrors[key] = nil
        } catch {
            saveErrors[key] = "Could not remove it from the Keychain: \(error)"
        }
        stored[key] = settings.hasSecret(adapter, field)
        results[adapter.name] = nil
    }

    /// True when every field has a value in Settings. Otherwise the script reads the env file.
    func complete(_ adapter: BuiltInAdapter) -> Bool {
        adapter.fields.allSatisfy { $0.secret ? hasSecret(adapter, $0) : !plainValue(adapter, $0).isEmpty }
    }

    /// The env file is what the adapter uses: not every field is set here, and the file exists.
    func usesEnvFile(_ adapter: BuiltInAdapter) -> Bool { !complete(adapter) && (envFiles[adapter.name] ?? false) }

    func lastRun(_ adapter: BuiltInAdapter) -> RunRecord? {
        store?.events.lastRuns["adapter:\(adapter.name)"] ?? previewRuns[adapter.name]
    }

    func check(_ adapter: BuiltInAdapter) {
        guard !checking.contains(adapter.name) else { return }
        checking.insert(adapter.name)
        results[adapter.name] = nil
        let settings = self.settings
        Task {
            let outcome = await settings.check(adapter.name)
            checking.remove(adapter.name)
            results[adapter.name] = outcome
        }
    }

    /// Previews: a check result to show.
    func pin(_ outcome: AdapterCheck.Outcome, for adapter: BuiltInAdapter) { results[adapter.name] = outcome }

    private func refreshCustom() {
        if let store { custom = store.runner.installed().adapters.filter { $0.builtIn != true } }
    }

    /// `~/.config/main-thing/adapters`, with the home folder as ~.
    var customFolder: String {
        let path = EventPlan.adaptersDirectory(settings.configDirectory).path
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// The Adapters tab: one section per built-in adapter, then the custom ones in the folder.
struct AdaptersSettings: View {
    let model: AdaptersModel

    var body: some View {
        Form {
            ForEach(BuiltInAdapters.all) { adapter in
                BuiltInAdapterSection(model: model, adapter: adapter)
            }
            customSection
        }
        .formStyle(.grouped)
        // Taller than most screens allow with everything open, so it scrolls.
        .frame(width: settingsWidth, height: 600)
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    private var customSection: some View {
        Section {
            if model.custom.isEmpty {
                Text("None in \(model.customFolder)")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.custom, id: \.path) { entry in
                    LabeledContent(entry.name) {
                        Text(customState(entry))
                            .foregroundStyle(entry.problem == nil ? .primary : .secondary)
                    }
                }
            }
        } header: {
            Text("Custom adapters")
        } footer: {
            if !model.custom.isEmpty {
                Text("Executables in \(model.customFolder)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func customState(_ entry: InstalledEntry) -> String {
        guard let problem = entry.problem else { return "May run" }
        if problem == EventRunner.shadowedProblem { return "Shadowed by the built-in" }
        return "Skipped: \(problem)"
    }
}

/// One built-in adapter: Enable, its fields, Check and the last run.
private struct BuiltInAdapterSection: View {
    let model: AdaptersModel
    let adapter: BuiltInAdapter

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.isEnabled(adapter) }, set: { model.setEnabled(adapter, $0) })) {
                Text("Enable")
                Text(adapter.summary)
            }
            ForEach(adapter.fields) { field in
                if field.secret {
                    SecretFieldRow(model: model, adapter: adapter, field: field)
                } else {
                    PlainFieldRow(model: model, adapter: adapter, field: field)
                }
            }
            if model.usesEnvFile(adapter) {
                Text("Using \(adapter.name).env in the config folder until every field here is set.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            checkRow
            lastRunRow
        } header: {
            Text(adapter.displayName)
        }
    }

    private var checkRow: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if model.checking.contains(adapter.name) {
                    ProgressView().controlSize(.small)
                }
                Button("Check") { model.check(adapter) }
                    .disabled(model.checking.contains(adapter.name))
            }
        } label: {
            switch model.results[adapter.name] {
            case .ok(let message)?:
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message)?:
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case nil:
                Text(model.checking.contains(adapter.name) ? "Checking…" : "Test the connection")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var lastRunRow: some View {
        if let run = model.lastRun(adapter) {
            LabeledContent {
                Text((run.ok ? "OK" : run.timedOut ? "Timed out" : "Failed, exit \(run.exit.map(String.init) ?? "signal")") + ", " + ago(run.at))
                    .foregroundStyle(run.ok ? Color.secondary : Color.red)
            } label: {
                Text("Last run")
                if !run.stderr.isEmpty {
                    Text(AdapterCheck.firstLine(run.stderr, adapter: adapter.name))
                }
            }
        } else {
            LabeledContent("Last run", value: "Not yet")
        }
    }
}

/// "just now", "5 minutes ago".
private func ago(_ date: Date) -> String {
    Date().timeIntervalSince(date) < 60 ? "just now" : date.formatted(.relative(presentation: .numeric))
}

/// The help line under a field: what it is, and a link to where to get it.
private func helpText(_ field: AdapterField) -> Text {
    var help = AttributedString(field.help + " ")
    var link = AttributedString(field.linkTitle)
    link.link = field.link
    help.append(link)
    return Text(help)
}

private struct PlainFieldRow: View {
    let model: AdaptersModel
    let adapter: BuiltInAdapter
    let field: AdapterField
    @State private var draft = ""

    var body: some View {
        LabeledContent {
            TextField("", text: $draft, prompt: Text(field.placeholder))
                .labelsHidden()
                .frame(width: 250)
                .onSubmit(save)
                .onChange(of: draft) { _, value in
                    if value.trimmingCharacters(in: .whitespaces) != model.plainValue(adapter, field) { save() }
                }
        } label: {
            Text(field.label)
            helpText(field)
        }
        .onAppear { draft = model.plainValue(adapter, field) }
    }

    private func save() { model.setPlainValue(draft, adapter, field) }
}

private struct SecretFieldRow: View {
    let model: AdaptersModel
    let adapter: BuiltInAdapter
    let field: AdapterField
    @State private var draft = ""
    @State private var replacing = false

    var body: some View {
        LabeledContent {
            if model.hasSecret(adapter, field) && !replacing {
                HStack(spacing: 8) {
                    Text("In Keychain")
                        .foregroundStyle(.secondary)
                    Button("Replace") { replacing = true }
                    Button("Remove") { model.removeSecret(adapter, field) }
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("", text: $draft, prompt: Text(field.placeholder))
                        .labelsHidden()
                        .frame(width: 190)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if replacing {
                        Button("Cancel") {
                            draft = ""
                            replacing = false
                        }
                    }
                }
            }
        } label: {
            Text(field.label)
            if let error = model.saveError(adapter, field) {
                Text(error).foregroundStyle(.red)
            } else {
                helpText(field)
            }
        }
    }

    private func save() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if model.saveSecret(draft, adapter, field) {
            draft = ""
            replacing = false
        }
    }
}
