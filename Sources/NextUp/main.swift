import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// LSUIElement in Info.plist does this for the bundle. Setting it here too covers `swift run`.
app.setActivationPolicy(.accessory)
app.run()
