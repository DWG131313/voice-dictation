import AppKit
import SwiftUI
import VoiceDictationLib

/// The floating indicator as `AppModel` drives it: `IndicatorPanel` in the
/// app, a fake in tests.
@MainActor
protocol IndicatorPresenting: AnyObject {
    /// Shows the indicator saying `state`, with `line`. Called again with each
    /// new level while recording.
    func show(_ state: DictationState, line: LevelLine)
    func hide()
}

/// The window the indicator floats in. It never takes focus from the app being
/// dictated into (Global Constraints): it never becomes key or main, it is a
/// non-activating panel ordered in without activating the app, and clicks go
/// through it. It floats over other apps, full-screen ones too, on every
/// Space, at the bottom centre of the screen with the mouse. It cannot become
/// main, so `WindowPolicy` never counts it as an open window, and showing it
/// changes no activation policy.
public final class IndicatorPanel: NSPanel {
    /// How far above the bottom of the screen's visible frame (above the Dock) it sits.
    public static let bottomMargin: CGFloat = 80

    private let host = NSHostingView(rootView: IndicatorView(state: .idle, level: LevelLine()))
    /// Measured when the panel is first shown, once the app has registered its fonts.
    private lazy var measuredSize = Self.indicatorSize()

    public init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = true
        // A panel hides when its app stops being active by default, and this
        // app is rarely active.
        hidesOnDeactivate = false
        // Closing the last window hides the app (`AppLifecycle.windowDidClose`);
        // the indicator must still show after that.
        canHide = false
        // Prism: no shadow. The panel is clear; the box draws its own black and hairline.
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        // The panel keeps one size; a narrower box sits centred in it.
        host.sizingOptions = []
        contentView = host
    }

    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }

    /// The panel's size: the recording layout's, the widest. The other
    /// states' boxes are as tall and sit centred in it, so every state stands
    /// `bottomMargin` above the bottom of the visible frame.
    static func indicatorSize() -> NSSize {
        let box = NSHostingView(rootView: IndicatorView(state: .recording(since: Date()), level: LevelLine())).fittingSize
        return NSSize(width: box.width.rounded(.up), height: box.height.rounded(.up))
    }

    /// Centred on `visibleFrame` on a whole point, `bottomMargin` above its bottom.
    static func frame(for size: NSSize, in visibleFrame: NSRect) -> NSRect {
        NSRect(x: (visibleFrame.midX - size.width / 2).rounded(), y: visibleFrame.minY + bottomMargin,
               width: size.width, height: size.height)
    }

    /// The visible frame of the screen the mouse is on, or of the first screen
    /// (the one with the menu bar) when it is on none. `NSMouseInRect`, because
    /// the mouse's y counts from 1: at the top of a screen it equals the
    /// frame's maxY, which `NSRect.contains` leaves out.
    static func visibleFrame(containing mouse: NSPoint, among screens: [(frame: NSRect, visibleFrame: NSRect)]) -> NSRect? {
        (screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? screens.first)?.visibleFrame
    }
}

extension IndicatorPanel: IndicatorPresenting {
    /// Shows `state` with `line`. A panel not yet on screen first moves to the
    /// bottom centre of the screen with the mouse, and is ordered in without
    /// becoming key or activating the app. One already on screen stays put and
    /// only its content changes.
    func show(_ state: DictationState, line: LevelLine) {
        host.rootView = IndicatorView(state: state, level: line)
        guard !isVisible else { return }
        let screens = NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) }
        if let visibleFrame = Self.visibleFrame(containing: NSEvent.mouseLocation, among: screens) {
            setFrame(Self.frame(for: measuredSize, in: visibleFrame), display: false)
        }
        orderFrontRegardless()
    }

    /// Takes the panel off screen and empties it, so no line or timer keeps
    /// running behind it.
    func hide() {
        orderOut(nil)
        host.rootView = IndicatorView(state: .idle, level: LevelLine())
    }
}
