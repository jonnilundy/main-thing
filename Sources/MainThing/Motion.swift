import SwiftUI

/// Motion tokens. Snappy with a little bounce. Nothing runs longer than about 300ms to settle,
/// except the tail of the open bounce. Reduce Motion: opacity only, ease out, never ease in.
enum Motion {
    /// Open: a fast rise, then a visible overshoot near full size and a settle.
    static let openSpring = Animation.spring(duration: 0.28, bounce: 0.35)
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

    /// Open content. It does not wait for the shape: opacity fades in over 120ms from the
    /// start, while it rises 4pt and scales from 0.97 with the open spring. Out: a quick fade.
    static func openContent(_ reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity.animation(reducedFade) }
        return .asymmetric(
            insertion: .opacity.animation(fade).combined(
                with: .modifier(
                    active: Rise(offset: 4, scale: 0.97),
                    identity: Rise(offset: 0, scale: 1)
                ).animation(openSpring)
            ),
            removal: .opacity.animation(fade)
        )
    }

    /// The collapsed title on open and close: a quick fade.
    static func collapsedTitle(_ reduceMotion: Bool) -> AnyTransition {
        .opacity.animation(reduceMotion ? reducedFade : fade)
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

/// Vertical offset and scale from the top edge, for content that rises into place.
struct Rise: ViewModifier {
    var offset: CGFloat
    var scale: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .scaleEffect(scale, anchor: .top)
    }
}
