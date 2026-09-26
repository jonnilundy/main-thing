import MainThingCore
import SwiftUI

/// The update lines for the notch's right click menu: "Install Update 0.2.1…" while an update
/// waits, and "Check for Updates…". Nothing when the updater is off (headless copies, or a build
/// without an update key). Drop `UpdateMenuItems()` into `NotchMenu`; it reads `Updater.shared`.
struct UpdateMenuItems: View {
    var body: some View {
        if let updater = Updater.shared, updater.state.running {
            if let available = updater.state.available {
                Button(UpdateRules.installTitle(version: available.version, ready: available.ready)) {
                    updater.installUpdate()
                }
            }
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheck)
        }
    }
}
