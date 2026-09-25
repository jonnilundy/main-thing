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

/// Where the collapsed notch sits on the primary screen.
public enum NotchMode: Equatable, Sendable {
    /// No hardware notch: the shape sits in the menu bar row, like a drawn housing.
    case inMenuBar
    /// A hardware notch: the shape hangs below the menu bar, centered under the housing.
    /// Nothing is drawn in the menu bar row.
    case belowMenuBar
}

/// Where the panel sits and how tall the collapsed notch is. Pure math over `ScreenInfo`.
/// The app adapts to the primary screen: in the menu bar row without a hardware notch,
/// below it with one. Recomputed on every display change.
public struct NotchGeometry: Equatable, Sendable {
    /// Fixed panel size. The notch draws at its top center and opens down into the rest.
    public static let panelSize = CGSize(width: 800, height: 260)
    /// Radius of the flared top corners, outside the content width.
    public static let flare: CGFloat = 8
    /// The MacBook Pro housing width. The collapsed shape is never narrower.
    public static let housingWidth: CGFloat = 185
    /// Collapsed height below a hardware notch.
    public static let belowMenuBarHeight: CGFloat = 30

    public var mode: NotchMode
    /// AppKit coordinates. Top edge on the screen top (in menu bar) or on the menu bar's
    /// bottom edge (below it), centered on `centerX`.
    public var panelFrame: CGRect
    public var menuBarHeight: CGFloat
    /// Screen x the notch is centered on: the housing center, else the screen center.
    public var centerX: CGFloat
    /// 0 in the menu bar mode.
    public var hardwareNotchWidth: CGFloat
    /// Collapsed drawn height: the menu bar height, or 30 below a hardware notch.
    public var notchHeight: CGFloat
    /// Collapsed content width floor, before the flares.
    public var minimumWidth: CGFloat

    public init(screen: ScreenInfo) {
        menuBarHeight = screen.menuBarHeight
        let size = NotchGeometry.panelSize
        let top: CGFloat
        if let housing = screen.hardwareNotch {
            mode = .belowMenuBar
            centerX = housing.midX
            hardwareNotchWidth = housing.width
            notchHeight = NotchGeometry.belowMenuBarHeight
            minimumWidth = max(housing.width, NotchGeometry.housingWidth) - 2 * NotchGeometry.flare
            top = screen.frame.maxY - menuBarHeight
        } else {
            mode = .inMenuBar
            centerX = screen.frame.midX
            hardwareNotchWidth = 0
            notchHeight = menuBarHeight
            minimumWidth = NotchGeometry.housingWidth - 2 * NotchGeometry.flare
            top = screen.frame.maxY
        }
        panelFrame = CGRect(
            x: (centerX - size.width / 2).rounded(),
            y: top - size.height,
            width: size.width,
            height: size.height
        )
    }

    public var hasHardwareNotch: Bool { mode == .belowMenuBar }

    /// The collapsed shape in panel coordinates, origin top left. It starts at y 0, the
    /// panel's top edge, so below a hardware notch no part of it is above the menu bar's bottom edge.
    public func collapsedShapeFrame(contentWidth: CGFloat) -> CGRect {
        let width = max(contentWidth, minimumWidth) + 2 * NotchGeometry.flare
        return CGRect(
            x: ((NotchGeometry.panelSize.width - width) / 2).rounded(),
            y: 0,
            width: width,
            height: notchHeight
        )
    }

    /// Always the primary screen, the one with the menu bar. A notch screen elsewhere does not win.
    public static func chooseScreen(_ screens: [ScreenInfo]) -> Int? {
        screens.isEmpty ? nil : 0
    }
}
