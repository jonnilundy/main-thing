import Foundation
import MainThingCore

@MainActor
func runShortcutChecks() {
    section("ShortcutPin")
    do {
        var pin = ShortcutPin(.list)
        check("a new pin holds with the pointer off the card", pin.holds(inside: false))
        check("it keeps holding while the pointer stays off", pin.holds(inside: false) && !pin.entered)
        check("the pointer reaching the card holds", pin.holds(inside: true) && pin.entered)
        check("moving on the card holds", pin.holds(inside: true))
        check("leaving the card after being on it ends the pin", !pin.holds(inside: false))
    }
    do {
        var pin = ShortcutPin(.list)
        pin.reason = .add
        check("the reason can move from list to add", pin.reason == .add && !pin.entered)
        check("an add pin ends the same way", pin.holds(inside: true) && !pin.holds(inside: false))
    }
}
