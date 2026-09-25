import SwiftUI

/// Motion tokens. One spring for the shape and the content, a fade when Reduce Motion is on.
enum Motion {
    /// Open, close, width and task changes. 300ms, a little bounce.
    static let spring = Animation.spring(duration: 0.3, bounce: 0.15)
    /// Reduce Motion: opacity only, ease out, never ease in.
    static let fade = Animation.easeOut(duration: 0.2)

    /// The shape does not animate under Reduce Motion, so nothing slides or grows.
    static func shape(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : spring
    }

    static func content(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : spring
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

    /// Open and close. Content fades with a light blur while the shape springs.
    static func fadeBlur(_ reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .modifier(
            active: Blend(offset: 0, opacity: 0, blur: 3),
            identity: Blend(offset: 0, opacity: 1, blur: 0)
        )
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
