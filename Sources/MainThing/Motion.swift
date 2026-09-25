import MainThingCore
import SwiftUI

/// Motion tokens. Snappy with a little bounce. Nothing runs longer than about 300ms to settle,
/// except the tail of the open bounce. Reduce Motion: opacity only, ease out, never ease in.
enum Motion {
    /// Open: a fast rise, then a visible overshoot near full size and a settle. Bounce 0.25,
    /// a touch more than the 0.2 Apple ships for sheets and drawers.
    static let openSpring = Animation.spring(duration: 0.28, bounce: 0.25)
    /// Close: quicker and calm, no bounce.
    static let closeSpring = Animation.spring(duration: 0.22, bounce: 0)
    /// Task change push.
    static let pushSpring = Animation.spring(duration: 0.3, bounce: 0.15)
    /// Done circle pop in on row hover, about 200ms with bounce.
    static let popSpring = Animation.spring(response: 0.2, dampingFraction: 0.55)
    /// Done circle hover, scale to 1.1 with bounce.
    static let bounceSpring = Animation.spring(response: 0.25, dampingFraction: 0.5)
    /// The strikethrough drawing left to right, and the text dimming with it.
    static let strike = Animation.easeOut(duration: 0.15)
    /// A second click erases the ink, fast.
    static let unstrike = Animation.easeOut(duration: 0.12)
    /// The hover preview of the cross off fading in.
    static let preview = Animation.easeOut(duration: 0.08)
    /// Pressed state on mouse down.
    static let press = Animation.easeOut(duration: 0.08)
    /// Scroll edge fades coming and going.
    static let edgeFade = Animation.easeOut(duration: 0.15)
    /// Quick fade for content that must not wait for the shape.
    static let fade = Animation.easeOut(duration: 0.12)
    /// Reduce Motion fade.
    static let reducedFade = Animation.easeOut(duration: 0.2)

    /// The shape: open spring when opening, close spring when closing. Nothing under Reduce Motion.
    static func shape(_ reduceMotion: Bool, opening: Bool) -> Animation? {
        reduceMotion ? nil : (opening ? openSpring : closeSpring)
    }

    /// Width and height follow a list change. Open: the open spring. Collapsed: the push spring.
    static func size(_ reduceMotion: Bool, open: Bool) -> Animation? {
        reduceMotion ? nil : (open ? openSpring : pushSpring)
    }

    /// Task change content.
    static func content(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedFade : pushSpring
    }

    /// Task change. The new title rises 10pt into place while it fades in and sharpens.
    /// The old one keeps rising 10pt while it fades out and blurs. Both only move up.
    static func push(_ reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .modifier(
                active: Blend(offset: 10, opacity: 0, blur: 3),
                identity: Blend(offset: 0, opacity: 1, blur: 0)
            ),
            removal: .modifier(
                active: Blend(offset: -10, opacity: 0, blur: 3),
                identity: Blend(offset: 0, opacity: 1, blur: 0)
            )
        )
    }

    /// A row or the count fading in with a 4pt rise while the card widens.
    static let rise = Animation.easeOut(duration: 0.18)

    /// The open card body. In: nothing of its own, the rows and the count each rise in on their
    /// own schedule. Out: a quick calm fade while the shape shrinks.
    static func openContent(_ reduceMotion: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .identity,
            removal: .opacity.animation(reduceMotion ? reducedFade : fade)
        )
    }

    /// Row `index` of rows 2..N on open: fades in with a 4pt rise, 20ms later per row, at most
    /// 120ms after the first. Out: the push, rising and blurring away, as when it is crossed off.
    /// Reduce Motion: opacity only.
    static func row(_ reduceMotion: Bool, index: Int) -> AnyTransition {
        if reduceMotion { return .opacity.animation(reducedFade) }
        return .asymmetric(
            insertion: .modifier(
                active: Blend(offset: 4, opacity: 0, blur: 0),
                identity: Blend(offset: 0, opacity: 1, blur: 0)
            ).animation(rise.delay(Lanes.rowDelay(index: index))),
            removal: .modifier(
                active: Blend(offset: -10, opacity: 0, blur: 3),
                identity: Blend(offset: 0, opacity: 1, blur: 0)
            ).animation(pushSpring)
        )
    }

    /// "1 of N" in the band: in with the first row, a 4pt rise; out with a quick fade.
    static func countFade(_ reduceMotion: Bool, opening: Bool) -> Animation {
        reduceMotion ? reducedFade : (opening ? rise : fade)
    }

    static func symbol(_ reduceMotion: Bool) -> ContentTransition {
        reduceMotion ? .opacity : .symbolEffect(.replace)
    }
}

/// Vertical offset, opacity and blur in one animatable modifier.
struct Blend: ViewModifier {
    var offset: CGFloat
    var opacity: Double
    var blur: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .opacity(opacity)
            .blur(radius: blur)
    }
}
