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

    private func soundPicker(_ sounds: Sounds) -> some View {
        let current = SoundChoice.resolve(stored: storedSound, available: soundFiles)
        let groups = SoundChoice.groups(customFiles: soundFiles)
        return Picker("Sound", selection: Binding(
            get: { current.stored },
            set: { value in
                let choice = SoundChoice.resolve(stored: value, available: soundFiles)
                sounds.choose(choice)
            }
        )) {
            ForEach(groups.indices, id: \.self) { index in
                if index > 0 { Divider() }
                Section {
                    ForEach(groups[index].choices, id: \.stored) { choice in
                        Text(choice.displayName).tag(choice.stored)
                    }
                } header: {
                    if let title = groups[index].title { Text(title) }
                }
            }
        }
    }

    private func linkSoundPicker(_ sounds: Sounds) -> some View {
        let current = LinkSound.resolve(stored: storedLinkSound)
        return Picker("Link sound", selection: Binding(
            get: { LinkSound.stored(current) },
            set: { value in sounds.chooseLink(LinkSound.resolve(stored: value)) }
        )) {
            ForEach(LinkSound.options, id: \.self) { cue in
                Text(LinkSound.displayName(cue)).tag(LinkSound.stored(cue))
                if cue == nil { Divider() }
            }
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
