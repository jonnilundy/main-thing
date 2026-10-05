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
    /// A hardware notch: the card hangs below the menu bar, centered under the housing, and a
    /// bridge fills the menu bar row under the camera, exactly the housing's width, so the camera
    /// notch and the card read as one black shape. Nothing else is drawn in the menu bar row.
    case belowMenuBar
}

/// Where the panel sits and how tall the collapsed notch is. Pure math over `ScreenInfo`.
/// The app adapts to the primary screen: in the menu bar row without a hardware notch,
/// below it with one, joined to the camera by the bridge. Recomputed on every display change.
/// The panel's top edge is the screen top in both modes.
public struct NotchGeometry: Equatable, Sendable {
    /// Fixed panel size. The notch draws at its top center and opens down into the rest.
    public static let panelSize = CGSize(width: 800, height: 260)
    /// Radius of the flared top corners, outside the content width.
    public static let flare: CGFloat = 8
    /// The MacBook Pro housing width. The collapsed shape is never narrower.
    public static let housingWidth: CGFloat = 185
    /// How far the black under a hardware notch reaches past each side of the reported housing.
    /// The auxiliary areas can end a bit short of the real cutout. A user's M5 MacBook Pro still
    /// showed a lit sliver of menu bar between the camera's edge and the card at 1pt, so the black
    /// reaches 3pt. The shape's straight sides are drawn by us from the screen top down, so the
    /// overdraw shows no step, only a slightly wider notch. Black beside the black camera does not
    /// show, a lit sliver does.
    public static let housingBleed: CGFloat = 3
    /// Collapsed height below a hardware notch. Short, so the closed notch does not hang far under
    /// the menu bar.
    public static let belowMenuBarHeight: CGFloat = 24
    /// The open card's band row below a hardware notch: task 1 as a full 28pt row with 1pt above
    /// and below. It stays taller than the collapsed band, so the open card keeps its rows.
    public static let openBandHeightBelowMenuBar: CGFloat = 30
    /// Hidden under a hardware notch: the black on each side of the camera housing. The dot sits
    /// in the left one, 11.5pt from the shape's edge and from the camera, the 7pt dot centered.
    public static let hiddenWing: CGFloat = 30
    /// Hidden without a hardware notch: the shape's width before the flares. 72 holds the 7pt dot
    /// with 32pt either side, so it reads as a deliberate small pill, not a sliver.
    public static let hiddenWidthInMenuBar: CGFloat = 72

    public var mode: NotchMode
    /// AppKit coordinates. Top edge on the screen top, centered on `centerX`.
    public var panelFrame: CGRect
    /// Where the card's top edge is, down from the panel's top: the bridge height (the menu bar
    /// row) with a hardware notch, 0 without.
    public var cardTop: CGFloat
    /// The bridge in panel coordinates, origin top left: the hardware notch's width (between the
    /// two auxiliary areas), from the screen top to the menu bar's bottom edge. Nil without a
    /// hardware notch.
    public var bridgeRect: CGRect?
    public var menuBarHeight: CGFloat
    /// Screen x the notch is centered on: the housing center, else the screen center.
    public var centerX: CGFloat
    /// 0 in the menu bar mode.
    public var hardwareNotchWidth: CGFloat
    /// Collapsed drawn height: the menu bar height, or 24 below a hardware notch.
    public var notchHeight: CGFloat
    /// The band row of the open card: the menu bar height without a hardware notch, 30 below one.
    /// Everything in the open card is laid out from this, never from `notchHeight`.
    public var openBandHeight: CGFloat
    /// Collapsed content width floor, before the flares. With a hardware notch it is the housing
    /// width, so the narrowest card continues the camera notch's sides straight down.
    public var minimumWidth: CGFloat
    /// Collapsed content width ceiling, before the flares. With a hardware notch it is the housing
    /// width too: the card continues the camera's sides straight down and a long title truncates.
    /// Nil without a hardware notch, where the card grows with its title. The open card ignores it.
    public var collapsedMaximumWidth: CGFloat?
    /// The chosen screen, for the open card's width and height caps.
    public var screenFrame: CGRect

    public init(screen: ScreenInfo) {
        menuBarHeight = screen.menuBarHeight
        screenFrame = screen.frame
        let size = NotchGeometry.panelSize
        let housing = screen.hardwareNotch
        if let housing {
            mode = .belowMenuBar
            centerX = housing.midX
            hardwareNotchWidth = housing.width
            notchHeight = NotchGeometry.belowMenuBarHeight
            openBandHeight = NotchGeometry.openBandHeightBelowMenuBar
            minimumWidth = max(housing.width, NotchGeometry.housingWidth) + 2 * NotchGeometry.housingBleed
            collapsedMaximumWidth = minimumWidth
            // Down to the menu bar's bottom edge, and never onto the camera.
            cardTop = max(menuBarHeight, housing.height)
        } else {
            mode = .inMenuBar
            centerX = screen.frame.midX
            hardwareNotchWidth = 0
            notchHeight = menuBarHeight
            openBandHeight = menuBarHeight
            minimumWidth = NotchGeometry.housingWidth - 2 * NotchGeometry.flare
            collapsedMaximumWidth = nil
            cardTop = 0
        }
        let frame = CGRect(
            x: (centerX - size.width / 2).rounded(),
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panelFrame = frame
        if let housing {
            bridgeRect = CGRect(x: housing.minX - NotchGeometry.housingBleed - frame.minX, y: 0, width: drawnHousingWidth, height: cardTop)
        } else {
            bridgeRect = nil
        }
    }

    public var hasHardwareNotch: Bool { mode == .belowMenuBar }

    /// The collapsed content width for a title that wants `natural` (`Lanes.collapsedWidth`).
    public func collapsedWidth(natural: CGFloat) -> CGFloat {
        min(natural, collapsedMaximumWidth ?? natural)
    }

    /// The panel frame with another height. The top edge stays where it is; the panel grows down.
    public func panelFrame(height: CGFloat) -> CGRect {
        CGRect(x: panelFrame.minX, y: panelFrame.maxY - height, width: panelFrame.width, height: height)
    }

    /// The collapsed card in panel coordinates, origin top left, flares included. It starts at
    /// `cardTop`: the panel's top edge, or below a hardware notch the menu bar's bottom edge, so
    /// no part of the card is in the menu bar row. The bridge is `bridgeRect`.
    public func collapsedShapeFrame(contentWidth: CGFloat) -> CGRect {
        let width = max(contentWidth, minimumWidth) + 2 * NotchGeometry.flare
        return CGRect(
            // Centered as the view centers it, unrounded: on a 2x screen a half point is a pixel,
            // and rounding would move the card half a point off the camera.
            x: (NotchGeometry.panelSize.width - width) / 2,
            y: cardTop,
            width: width,
            height: notchHeight
        )
    }

    /// Hidden: the closed notch folds into the menu bar row and shows only the dot. Its content
    /// width before the flares: the camera housing and a wing on each side under a hardware
    /// notch, a small pill without.
    public var hiddenWidth: CGFloat {
        hasHardwareNotch ? drawnHousingWidth + 2 * NotchGeometry.hiddenWing : NotchGeometry.hiddenWidthInMenuBar
    }

    /// The black drawn under the camera: the reported housing plus the bleed on each side. The
    /// bridge has this width, and the hidden wings are measured from its edges. 0 without a hardware notch.
    public var drawnHousingWidth: CGFloat {
        hasHardwareNotch ? hardwareNotchWidth + 2 * NotchGeometry.housingBleed : 0
    }

    /// The hidden shape's height: the menu bar row, never above the camera's own height.
    public var hiddenHeight: CGFloat { hasHardwareNotch ? cardTop : notchHeight }

    /// The hidden dot's center from the shape's left edge: the middle of the left wing under a
    /// hardware notch, the middle of the pill without.
    public var hiddenDotX: CGFloat {
        hasHardwareNotch ? NotchGeometry.hiddenWing / 2 : hiddenWidth / 2
    }

    /// The hidden shape in panel coordinates, origin top left, flares not included. The panel is
    /// centered on the shape, as the bridge is on the camera.
    public var hiddenRect: CGRect {
        CGRect(x: (NotchGeometry.panelSize.width - hiddenWidth) / 2, y: 0, width: hiddenWidth, height: hiddenHeight)
    }

    /// What counts as the bridge for hover. Hidden under a hardware notch the shape is all menu bar
    /// row: the camera and its two wings. Open or collapsed, the bridge is the camera's width.
    /// Without a hardware notch there is no bridge and the view's own shape rect is the test.
    public func hoverBridge(hidden: Bool) -> CGRect? {
        hasHardwareNotch && hidden ? hiddenRect : bridgeRect
    }

    /// The bridge's center, from the panel's horizontal center. The card is centered in the
    /// panel, so this places the bridge over the camera exactly. 0 without a hardware notch.
    public var bridgeOffset: CGFloat {
        bridgeRect.map { $0.midX - panelFrame.width / 2 } ?? 0
    }

    /// Does the collapsed notch draw anything for a list of `taskCount` tasks? Under a hardware
    /// notch an empty list draws no card: only the black bridge over the camera, which looks like
    /// the camera notch itself. Hovering it opens the card. Without a hardware notch the plain
    /// shape always shows.
    public func drawsCollapsed(taskCount: Int) -> Bool {
        !(hasHardwareNotch && taskCount <= 0)
    }

    /// Always the primary screen, the one with the menu bar. A notch screen elsewhere does not win.
    public static func chooseScreen(_ screens: [ScreenInfo]) -> Int? {
        screens.isEmpty ? nil : 0
    }
}
