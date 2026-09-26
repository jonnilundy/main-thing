import AppKit
import MainThingCore
import ServiceManagement
import SwiftUI

/// The content of the Settings window. Sound and Reminder read and write the same UserDefaults
/// keys as the right click menu, so a change in one shows in the other.
struct SettingsView: View {
    let sounds: Sounds?
    let updater: Updater?

    @AppStorage(Sounds.key) private var storedSound: String = SoundChoice.penKey
    @AppStorage(Reminder.key) private var storedReminder: Int = ReminderSchedule.defaultInterval
    @State private var loginStatus = LaunchAtLogin.status
    @State private var soundFiles: [String] = []

    var body: some View {
        Form {
            Section("General") {
                launchAtLogin
                if let sounds { soundPicker(sounds) }
                reminderPicker
            }
            Section("Updates") {
                updates
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
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
        let choices: [SoundChoice] = [.pen] + soundFiles.map { .custom(fileName: $0) } + [.off]
        return Picker("Sound", selection: Binding(
            get: { current.stored },
            set: { value in
                let choice = SoundChoice.resolve(stored: value, available: soundFiles)
                sounds.choose(choice)
            }
        )) {
            ForEach(choices, id: \.stored) { choice in
                Text(choice.displayName).tag(choice.stored)
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

    @ViewBuilder private var updates: some View {
        let (version, build) = Updater.bundleVersion
        LabeledContent("Version", value: UpdateRules.versionLabel(version: version, build: build))
        if let updater, updater.state.running {
            let state = updater.state
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
                Text(UpdateRules.lastCheckLabel(date: state.lastCheck, result: state.lastResult))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(updater?.state.lastResult.isEmpty == false ? updater!.state.lastResult : "Updates are off in this copy")
                .foregroundStyle(.secondary)
        }
    }
}
