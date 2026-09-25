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

    /// Task change: the new one pushes up from the bottom, the old one leaves through the top.
    static func push(_ reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }

    static func symbol(_ reduceMotion: Bool) -> ContentTransition {
        reduceMotion ? .opacity : .symbolEffect(.replace)
    }
}
