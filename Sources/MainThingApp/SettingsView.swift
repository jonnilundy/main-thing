import AppKit
import MainThingCore
import ServiceManagement
import SwiftUI

/// The width every Settings tab shares.
let settingsWidth: CGFloat = 480

/// The General tab. Sound, Link sound and Reminder read and write the same UserDefaults keys as
/// the right click menu, so a change in one shows in the other.
struct GeneralSettings: View {
    let sounds: Sounds?

    /// Nil until a sound is picked: nothing stored is the default cue, not a stored value.
    @AppStorage(Sounds.key) private var storedSound: String?
    @AppStorage(LinkSound.key) private var storedLinkSound: String?
    @AppStorage(Reminder.key) private var storedReminder: Int = ReminderSchedule.defaultInterval
    @State private var loginStatus = LaunchAtLogin.status
    @State private var soundFiles: [String] = []

    var body: some View {
        Form {
            Section {
                launchAtLogin
                if let sounds {
                    soundPicker(sounds)
                    linkSoundPicker(sounds)
                }
                reminderPicker
                LabeledContent("Tasks file") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([TaskStore.defaultFileURL]) }
                }
                LabeledContent("Command line tool") {
                    Button("Install") { CommandLineTool.installFromMenu() }
                }
            }
        }
        .settingsTab()
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        loginStatus = LaunchAtLogin.status
        soundFiles = sounds?.available() ?? []
    }

    @ViewBuilder private var launchAtLogin: some View {
        if loginStatus == .requiresApproval {
            LabeledContent("Launch at Login") {
                Button("Approve in System Settings") { LaunchAtLogin.openSettings() }
            }
        } else {
            Toggle("Launch at Login", isOn: Binding(
                get: { loginStatus == .enabled },
                set: { on in
                    do {
                        loginStatus = try LaunchAtLogin.setEnabled(on)
                        if loginStatus == .requiresApproval { LaunchAtLogin.openSettings() }
                    } catch {
                        NSSound.beep()
                        loginStatus = LaunchAtLogin.status
                    }
                }
            ))
        }
    }

    /// Pointing at an option in the menu plays it; picking one stores it.
    private func soundPicker(_ sounds: Sounds) -> some View {
        let current = SoundChoice.resolve(stored: storedSound, available: soundFiles)
        var entries: [SoundPopUp.Entry] = []
        for (index, group) in SoundChoice.groups(customFiles: soundFiles).enumerated() {
            if index > 0 { entries.append(.divider) }
            if let title = group.title { entries.append(.header(title)) }
            entries += group.choices.map { .option(title: $0.displayName, value: $0.stored) }
        }
        let files = soundFiles
        return LabeledContent("Sound") {
            PlayButton(label: "Play the done sound") { sounds.previewDone() }
            SoundPopUp(
                entries: entries,
                selected: current.stored,
                onSelect: { value in Sounds.store(SoundChoice.resolve(stored: value, available: files)) },
                onHover: { value in sounds.preview(SoundChoice.resolve(stored: value, available: files)) }
            )
        }
    }

    private func linkSoundPicker(_ sounds: Sounds) -> some View {
        let current = LinkSound.resolve(stored: storedLinkSound)
        var entries: [SoundPopUp.Entry] = []
        for cue in LinkSound.options {
            entries.append(.option(title: LinkSound.displayName(cue), value: LinkSound.stored(cue)))
            if cue == nil { entries.append(.divider) }
        }
        return LabeledContent("Link sound") {
            PlayButton(label: "Play the link sound") { sounds.previewLink() }
            SoundPopUp(
                entries: entries,
                selected: LinkSound.stored(current),
                onSelect: { value in Sounds.storeLink(LinkSound.resolve(stored: value)) },
                onHover: { value in sounds.preview(link: LinkSound.resolve(stored: value)) }
            )
        }
    }

    private var reminderPicker: some View {
        let current = ReminderSchedule.interval(stored: storedReminder)
        var seconds = ReminderSchedule.menuMinutes.map { $0 * 60 }
        if !seconds.contains(current) { seconds.append(current) }
        return Picker("Reminder", selection: Binding(
            get: { current },
            set: { Reminder.store(seconds: $0) }
        )) {
            ForEach(seconds, id: \.self) { value in
                Text(value % 60 == 0 ? ReminderSchedule.label(minutes: value / 60) : "\(value) seconds").tag(value)
            }
        }
    }
}

/// The Shortcuts tab.
struct ShortcutsSettings: View {
    var body: some View {
        Form { ShortcutsSection() }
            .settingsTab()
    }
}

/// The Updates tab: version, Check Now, automatic checks, the last check.
struct UpdatesSettings: View {
    let updater: Updater?

    var body: some View {
        Form {
            Section { updates }
        }
        .settingsTab()
    }

    @ViewBuilder private var updates: some View {
        let (version, build) = Updater.bundleVersion
        LabeledContent("Version", value: UpdateRules.versionLabel(version: version, build: build))
        if let updater, updater.state.running {
            let state = updater.state
            if let latest = state.latest {
                LabeledContent("Latest", value: latest)
            }
            if let available = state.available {
                LabeledContent("Available") {
                    Button(UpdateRules.installTitle(version: available.version, ready: available.ready)) {
                        updater.installUpdate()
                    }
                }
            }
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updater.automaticallyChecks },
                set: { updater.automaticallyChecks = $0 }
            ))
            LabeledContent {
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(state.checking)
            } label: {
                Text(UpdateRules.lastCheckLabel(date: state.lastCheck, result: state.lastResult, checking: state.checking))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(updater?.state.lastResult.isEmpty == false ? updater!.state.lastResult : "Updates are off in this copy")
                .foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// One Settings tab: a grouped form at the shared width, as tall as its content.
    func settingsTab() -> some View {
        formStyle(.grouped)
            .frame(width: settingsWidth)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Plays the sound picked beside it, so the options can be tried one after another.
private struct PlayButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.circle")
                .imageScale(.large)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}
