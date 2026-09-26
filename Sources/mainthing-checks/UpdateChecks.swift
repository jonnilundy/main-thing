import Foundation
import MainThingCore

@MainActor
func runUpdateChecks() {
    section("Updates")
    let key = Data(repeating: 7, count: 32).base64EncodedString()
    check("a 32 byte base64 key starts the updater", UpdateRules.hasPublicKey(key))
    check("the placeholder keeps the updater off", UpdateRules.hasPublicKey(UpdateRules.placeholderKey) == false)
    check("the placeholder is the one in Info.plist", UpdateRules.placeholderKey == "REPLACE-WITH-PUBLIC-KEY")
    check("no key keeps it off", UpdateRules.hasPublicKey(nil) == false && UpdateRules.hasPublicKey("") == false)
    check("a 31 byte key keeps it off", UpdateRules.hasPublicKey(Data(repeating: 7, count: 31).base64EncodedString()) == false)
    check("not base64 keeps it off", UpdateRules.hasPublicKey("not a key!") == false)
    check("install title for a found update opens a window", UpdateRules.installTitle(version: "0.2.1", ready: false) == "Install Update 0.2.1…")
    check("install title for a downloaded update relaunches", UpdateRules.installTitle(version: "0.2.1", ready: true) == "Install Update 0.2.1 and Relaunch")
    check("version label", UpdateRules.versionLabel(version: "0.2.1", build: "3") == "0.2.1 (3)")
    check("version label without a separate build", UpdateRules.versionLabel(version: "3", build: "3") == "3")
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    check("never checked", UpdateRules.lastCheckLabel(date: nil, result: "", now: now) == "Never checked")
    check("checked just now", UpdateRules.lastCheckLabel(date: now.addingTimeInterval(-5), result: "Up to date", now: now) == "Checked just now: Up to date")
    check("checked hours ago", UpdateRules.lastCheckLabel(date: now.addingTimeInterval(-7200), result: "Up to date", now: now).hasPrefix("Checked 2 hours ago"))
}
