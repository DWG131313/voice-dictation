import CoreGraphics

/// Which edge of the front window the mini view's tab sits against.
enum MiniViewSide: Equatable { case right, left }

/// Where the mini view's tab and its panel go. Pure geometry; every rect is
/// AppKit's (origin bottom-left, y up).
enum MiniViewLayout {
    static let tabWidth: CGFloat = 40
    static let topInset: CGFloat = 40

    /// The tab against the chosen side, `topInset` below the window's top.
    /// With no room on that side it flips; with none on either it sits just
    /// inside the window on the chosen side. Never below the screen.
    static func tabFrame(window: CGRect, side: MiniViewSide, tabHeight: CGFloat, visibleFrame: CGRect) -> CGRect {
        let right = window.maxX
        let left = window.minX - tabWidth
        func fits(_ x: CGFloat) -> Bool { x >= visibleFrame.minX && x + tabWidth <= visibleFrame.maxX }

        let x: CGFloat
        switch side {
        case .right:
            x = fits(right) ? right : fits(left) ? left : window.maxX - tabWidth
        case .left:
            x = fits(left) ? left : fits(right) ? right : window.minX
        }
        var y = window.maxY - topInset - tabHeight
        y = min(y, visibleFrame.maxY - tabHeight)
        y = max(y, visibleFrame.minY)
        return CGRect(x: x, y: y, width: tabWidth, height: tabHeight)
    }

    /// The panel on the far side of the tab from the window, tops aligned;
    /// mirrored over the window when it doesn't fit. Kept inside `visibleFrame`.
    static func panelFrame(tab: CGRect, window: CGRect, panelSize: CGSize, visibleFrame: CGRect) -> CGRect {
        let tabOnRight = tab.midX >= window.midX
        let beyond = tabOnRight ? tab.maxX : tab.minX - panelSize.width
        let mirrored = tabOnRight ? tab.minX - panelSize.width : tab.maxX
        func fits(_ x: CGFloat) -> Bool { x >= visibleFrame.minX && x + panelSize.width <= visibleFrame.maxX }

        var x = fits(beyond) ? beyond : mirrored
        x = max(min(x, visibleFrame.maxX - panelSize.width), visibleFrame.minX)
        var y = tab.maxY - panelSize.height
        y = max(min(y, visibleFrame.maxY - panelSize.height), visibleFrame.minY)
        return CGRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
    }

    /// The side a tab dropped at `midX` belongs to: the window's nearer half.
    static func side(droppedAt midX: CGFloat, window: CGRect) -> MiniViewSide {
        midX >= window.midX ? .right : .left
    }

    /// Accessibility reports top-left coordinates from the primary screen's
    /// top; AppKit's origin is its bottom-left.
    static func appKitFrame(axPosition: CGPoint, axSize: CGSize, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: axPosition.x, y: primaryScreenHeight - axPosition.y - axSize.height,
               width: axSize.width, height: axSize.height)
    }
}
