import AppKit
import SwiftUI

/// The mini view's two windows, the tab and the panel it opens. Neither may
/// take focus from the app in front (Global Constraints): they never become
/// key or main, and are non-activating panels ordered in without activating
/// the app, so a click on them leaves the app in front in front. They float
/// above other apps' windows on every Space and stay shown while this app is
/// inactive or hidden. Each draws its own black and hairline: no shadow, a
/// clear window.
class MiniViewPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // A panel hides when its app stops being active by default, and this
        // app is rarely active.
        hidesOnDeactivate = false
        // Closing the last window hides the app (`AppLifecycle.windowDidClose`).
        canHide = false
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A hosting view that acts on the first click. The app is never active and
/// these windows never become key, so every click is a first click.
class MiniHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The tab's window, as tall as the controller makes it.
final class MiniTabPanel: MiniViewPanel {
    /// A click on the tab, without a drag.
    var onClick: (() -> Void)? {
        get { host.onClick }
        set { host.onClick = newValue }
    }
    /// The end of a drag, with the tab's middle on the screen's x axis.
    var onDrop: ((CGFloat) -> Void)? {
        get { host.onDrop }
        set { host.onDrop = newValue }
    }

    private let host = MiniTabHostingView(rootView: MiniTabContent())

    override init() {
        super.init()
        // The panel keeps the size it is given.
        host.sizingOptions = []
        contentView = host
    }

    /// Draws `content` at `frame`, ordered in without activating the app.
    func show(_ content: MiniTabContent, at frame: CGRect) {
        host.rootView = content
        if self.frame != frame { setFrame(frame, display: true) }
        if !isVisible { orderFrontRegardless() }
    }

    /// Draws `content` where the tab is.
    func draw(_ content: MiniTabContent) {
        host.rootView = content
    }

    /// Takes the tab off screen and empties it, so no line keeps running behind it.
    func hide() {
        orderOut(nil)
        host.rootView = MiniTabContent()
    }
}

/// The tab's view, which takes its own clicks and drags. A press let go
/// within `dragThreshold` of where it went down is a click; one that goes
/// further drags the tab sideways with the pointer until it is let go.
final class MiniTabHostingView: MiniHostingView<MiniTabContent> {
    static let dragThreshold: CGFloat = 3

    var onClick: (() -> Void)?
    var onDrop: ((CGFloat) -> Void)?
    /// Where the pointer and the window were when the button went down, in
    /// screen coordinates; nil when no press is under way.
    private var press: (pointer: CGPoint, origin: CGPoint)?
    private var isDragging = false

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        press = (NSEvent.mouseLocation, window.frame.origin)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press, let window else { return }
        let pointer = NSEvent.mouseLocation
        let dx = pointer.x - press.pointer.x
        if !isDragging {
            guard hypot(dx, pointer.y - press.pointer.y) >= Self.dragThreshold else { return }
            isDragging = true
        }
        window.setFrameOrigin(NSPoint(x: press.origin.x + dx, y: press.origin.y))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            press = nil
            isDragging = false
        }
        guard press != nil, let window else { return }
        if isDragging {
            onDrop?(window.frame.midX)
        } else {
            onClick?()
        }
    }
}

/// The panel a click on the tab opens, beside it, as tall as what it shows.
final class MiniInfoPanel: MiniViewPanel {
    private let host = MiniHostingView(rootView: MiniPanelView(transcript: nil, now: Date(), copy: {}, open: {}))

    override init() {
        super.init()
        host.sizingOptions = []
        contentView = host
    }

    /// Shows `content` beside `tab` on `window`'s screen, ordered in without
    /// activating the app.
    func show(_ content: MiniPanelView, besideTab tab: CGRect, on window: FrontWindow) {
        host.rootView = content
        // Measured in a hosting view of its own, as the indicator measures
        // its size: this one keeps the size it is given.
        let size = NSHostingView(rootView: content).fittingSize
        setFrame(Self.frame(size: size, besideTab: tab, on: window), display: true)
        if !isVisible { orderFrontRegardless() }
    }

    /// Moves the panel, as it is, beside `tab`: the window moved.
    func place(besideTab tab: CGRect, on window: FrontWindow) {
        setFrame(Self.frame(size: frame.size, besideTab: tab, on: window), display: true)
    }

    private static func frame(size: CGSize, besideTab tab: CGRect, on window: FrontWindow) -> CGRect {
        MiniViewLayout.panelFrame(tab: tab, window: window.frame, panelSize: size, visibleFrame: window.visibleFrame)
    }

    func hide() {
        orderOut(nil)
    }
}
