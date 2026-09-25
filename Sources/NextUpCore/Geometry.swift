import CoreGraphics
import Foundation

/// What the app reads from an `NSScreen`. Plain data, so checks can run on fixtures.
/// Rects use AppKit screen coordinates: origin bottom left.
public struct ScreenInfo: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var safeAreaTop: CGFloat
    public var auxiliaryTopLeft: CGRect?
    public var auxiliaryTopRight: CGRect?

    public init(
        frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat = 0,
        auxiliaryTopLeft: CGRect? = nil, auxiliaryTopRight: CGRect? = nil
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
    }

    /// Height of the menu bar row. 30 when the screen reports nothing usable.
    public var menuBarHeight: CGFloat {
        let height = frame.maxY - visibleFrame.maxY
        return height > 0 ? height : 30
    }

    /// The camera housing, between the two auxiliary areas. Nil without a hardware notch.
    public var hardwareNotch: CGRect? {
        guard safeAreaTop > 0, let left = auxiliaryTopLeft, let right = auxiliaryTopRight,
              right.minX > left.maxX
        else { return nil }
        return CGRect(x: left.maxX, y: frame.maxY - safeAreaTop, width: right.minX - left.maxX, height: safeAreaTop)
    }
}

/// Where the panel sits and how tall the collapsed notch is. Pure math over `ScreenInfo`.
public struct NotchGeometry: Equatable, Sendable {
    /// Fixed panel size. The notch draws at its top center and opens down into the rest.
    public static let panelSize = CGSize(width: 800, height: 260)
    /// Radius of the flared top corners, outside the content width.
    public static let flare: CGFloat = 8
    /// Under a hardware notch the title sits in this band below the camera.
    public static let bandHeight: CGFloat = 24
    /// Collapsed width floor when there is no hardware notch and no title.
    public static let plainMinimumWidth: CGFloat = 140

    public var panelFrame: CGRect
    public var menuBarHeight: CGFloat
    /// 0 without a hardware notch.
    public var safeAreaTop: CGFloat
    /// 0 without a hardware notch.
    public var hardwareNotchWidth: CGFloat
    /// Collapsed drawn height: the menu bar row, or the safe area plus the title band.
    public var notchHeight: CGFloat
    /// The part of the notch row that holds the title, at its bottom.
    public var titleBandHeight: CGFloat
    /// Collapsed content width floor, before the flares.
    public var minimumWidth: CGFloat

    public init(screen: ScreenInfo) {
        let size = NotchGeometry.panelSize
        panelFrame = CGRect(
            x: (screen.frame.midX - size.width / 2).rounded(),
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        menuBarHeight = screen.menuBarHeight
        if let notch = screen.hardwareNotch {
            safeAreaTop = screen.safeAreaTop
            hardwareNotchWidth = notch.width
            notchHeight = screen.safeAreaTop + NotchGeometry.bandHeight
            titleBandHeight = NotchGeometry.bandHeight
            // Match the housing's outer width, so the drawn shape is never narrower than the camera.
            minimumWidth = max(notch.width - 2 * NotchGeometry.flare, NotchGeometry.plainMinimumWidth)
        } else {
            safeAreaTop = 0
            hardwareNotchWidth = 0
            notchHeight = menuBarHeight
            titleBandHeight = menuBarHeight
            minimumWidth = NotchGeometry.plainMinimumWidth
        }
    }

    public var hasHardwareNotch: Bool { hardwareNotchWidth > 0 }

    /// The screen with a hardware notch when one is on, else the first (primary) screen.
    public static func chooseScreen(_ screens: [ScreenInfo]) -> Int? {
        if let index = screens.firstIndex(where: { $0.hardwareNotch != nil }) { return index }
        return screens.isEmpty ? nil : 0
    }
}
