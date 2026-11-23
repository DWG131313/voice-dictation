import AppKit
import ApplicationServices
import QuartzCore
import VoiceDictationLib

/// Watches which window is in front and where it is, for the mini view's tab.
@MainActor protocol FrontWindowWatching: AnyObject {
    /// Called after every change, with nil when the tab may not show.
    var onChange: ((FrontWindow?) -> Void)? { get set }
    var current: FrontWindow? { get }
    func start()
    func stop()
}

/// Follows the frontmost app through `NSWorkspace` and its focused window
/// through one `AXObserver`: macOS's notifications. While the window moves,
/// its bounds are also read from the window server every screen frame, until
/// it has been still for a moment (`MoveFollower`); no timer runs otherwise.
/// It reads only a window's subrole, full-screen and minimised state,
/// position and size; never its title or contents. Without Accessibility,
/// `current` stays nil. VoiceDictation's own windows are not followed.
@MainActor final class FrontWindowTracker: FrontWindowWatching {
    var onChange: ((FrontWindow?) -> Void)?
    private(set) var current: FrontWindow?

    /// Tries again to follow an app too busy to answer, just launched.
    private var retry = FollowRetry()
    private var retryTask: Task<Void, Never>?

    /// While the window moves: the per-frame rule, its tick, and the window
    /// server's number for the window (found when it is focused).
    private var follower = MoveFollower()
    private var ticker: DisplayTicker?
    private var serverNumber: CGWindowID?
    /// The focused window's frame as Accessibility last gave it, top-left.
    private var axFrame: CGRect?

    /// The front app being followed, and the observer that tells of it.
    private struct FollowedApp {
        let pid: pid_t
        let element: AXUIElement
        let observer: AXObserver
    }

    private var activation: NSObjectProtocol?
    private var app: FollowedApp?
    /// The app's focused window, carrying `windowNotifications`.
    private var window: AXUIElement?

    /// One Accessibility call may wait this long (`PasteEngine`'s constant, so
    /// the 0.25 s lives in one place). Set per element: a window's element does
    /// not take it from its app's.
    private static let messagingTimeout = PasteEngine.accessibilityMessagingTimeout

    private static let windowNotifications = [
        kAXMovedNotification, kAXResizedNotification,
        kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
    ]

    init() {}

    isolated deinit { stop() }

    /// The tab sits only on another app's standard window that is neither
    /// full screen nor minimised.
    nonisolated static func shows(subrole: String?, isFullScreen: Bool, isMinimized: Bool, isOwnApp: Bool) -> Bool {
        subrole == kAXStandardWindowSubrole && !isFullScreen && !isMinimized && !isOwnApp
    }

    func start() {
        guard activation == nil else { return }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated { self?.follow(pid: pid) }
        }
        follow(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    /// Takes off every observer, notification and run loop source, so
    /// nothing calls back after this. `current` goes back to nil quietly.
    func stop() {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        retryTask?.cancel()
        retryTask = nil
        unfollowApp()
        current = nil
    }

    /// From the observer's callback, on the main thread.
    fileprivate func handle(_ notification: String) {
        guard app != nil else { return }
        switch notification {
        case kAXFocusedWindowChangedNotification, kAXUIElementDestroyedNotification:
            focusChanged()
        case kAXMovedNotification, kAXResizedNotification:
            moved()
        default:
            refresh()
        }
    }

    // MARK: - Following

    /// The app now in front: a new observer for a new app, a fresh read of
    /// the same one. An app too busy to answer is tried again (`FollowRetry`).
    private func follow(pid: pid_t?, retrying: Bool = false) {
        retryTask?.cancel()
        retryTask = nil
        if !retrying { retry.reset() }
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier, AXIsProcessTrusted() else {
            unfollowApp()
            update(nil)
            return
        }
        if app?.pid != pid {
            unfollowApp()
            switch Self.observe(pid: pid, refcon: Unmanaged.passUnretained(self).toOpaque()) {
            case .followed(let followed):
                app = followed
            case .failed(let error):
                tryAgainLater(pid: pid, after: error)
            }
        }
        focusChanged()
    }

    /// Follows `pid` again after a wait, while it is still in front; or gives up.
    private func tryAgainLater(pid: pid_t, after error: AXError) {
        guard let delay = retry.failed(error) else {
            Log.info("[MINI] Cannot follow the front app's windows (AXError \(error.rawValue))")
            return
        }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self?.follow(pid: pid, retrying: true)
        }
    }

    /// An app followed, or why it could not be.
    private enum Observed {
        case followed(FollowedApp)
        case failed(AXError)
    }

    private static func observe(pid: pid_t, refcon: UnsafeMutableRawPointer) -> Observed {
        var created: AXObserver?
        let made = AXObserverCreate(pid, frontWindowNotified, &created)
        guard made == .success, let observer = created else { return .failed(made) }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        let added = AXObserverAddNotification(observer, element, kAXFocusedWindowChangedNotification as CFString, refcon)
        guard added == .success else { return .failed(added) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        return .followed(FollowedApp(pid: pid, element: element, observer: observer))
    }

    private func unfollowApp() {
        unwatchWindow()
        guard let app else { return }
        AXObserverRemoveNotification(app.observer, app.element, kAXFocusedWindowChangedNotification as CFString)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(app.observer), .defaultMode)
        self.app = nil
    }

    /// Moves the window notifications to the app's focused window, then reads it.
    private func focusChanged() {
        unwatchWindow()
        if let app, let value = Self.attribute(app.element, kAXFocusedWindowAttribute),
           CFGetTypeID(value) == AXUIElementGetTypeID() {
            let focused = value as! AXUIElement
            AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for name in Self.windowNotifications {
                AXObserverAddNotification(app.observer, focused, name as CFString, refcon)
            }
            window = focused
        }
        refresh()
        // Usually still now, so its frame matches the window server's exactly.
        serverNumber = matchServerNumber()
    }

    private func unwatchWindow() {
        stopFollowingMoves()
        serverNumber = nil
        if let app, let window {
            for name in Self.windowNotifications {
                AXObserverRemoveNotification(app.observer, window, name as CFString)
            }
        }
        window = nil
    }

    /// Reads the focused window again and reports it, or nil when the tab may not show.
    private func refresh() {
        guard let app, let window, let primary = NSScreen.screens.first,
              Self.shows(subrole: Self.attribute(window, kAXSubroleAttribute) as? String,
                         isFullScreen: Self.attribute(window, "AXFullScreen") as? Bool ?? false,
                         isMinimized: Self.attribute(window, kAXMinimizedAttribute) as? Bool ?? false,
                         isOwnApp: app.pid == ProcessInfo.processInfo.processIdentifier),
              let position = Self.position(window), let size = Self.size(window) else {
            axFrame = nil
            update(nil)
            return
        }
        axFrame = CGRect(origin: position, size: size)
        let frame = MiniViewLayout.appKitFrame(axPosition: position, axSize: size,
                                               primaryScreenHeight: primary.frame.height)
        update(FrontWindow(id: WindowIdentity(pid: app.pid, token: WindowToken(element: window)),
                           frame: frame, visibleFrame: Self.screen(containing: frame, primary: primary).visibleFrame))
    }

    /// The screen with the frame's centre on it, else the primary one.
    private static func screen(containing frame: CGRect, primary: NSScreen) -> NSScreen {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(centre) } ?? primary
    }

    // MARK: - Moving windows

    /// A move or resize report. The first starts following the window every
    /// screen frame; while following, a report only keeps it going, since its
    /// position can trail the window server's and would pull the tab back.
    private func moved() {
        let now = ProcessInfo.processInfo.systemUptime
        if ticker != nil, let current {
            follower.reported(current.frame, at: now)
            return
        }
        refresh()
        guard let current, app != nil, let primary = NSScreen.screens.first else { return }
        if serverNumber == nil { serverNumber = matchServerNumber() }
        guard serverNumber != nil else { return }
        follower.reported(current.frame, at: now)
        let ticker = DisplayTicker { [weak self] in self?.followTick() }
        ticker.start(on: Self.screen(containing: current.frame, primary: primary))
        self.ticker = ticker
    }

    /// One screen frame while the window moves: the tab goes where the
    /// window server has the window. Once it has been still, Accessibility
    /// has the last word.
    private func followTick() {
        guard let serverNumber, let current, let primary = NSScreen.screens.first else {
            stopFollowingMoves()
            return
        }
        let frame = WindowServerFrame.frame(of: serverNumber).map {
            MiniViewLayout.appKitFrame(axPosition: $0.origin, axSize: $0.size, primaryScreenHeight: primary.frame.height)
        }
        switch follower.tick(frame, at: ProcessInfo.processInfo.systemUptime) {
        case .moved(let frame):
            update(FrontWindow(id: current.id, frame: frame,
                               visibleFrame: Self.screen(containing: frame, primary: primary).visibleFrame))
        case .still:
            break
        case .stop:
            stopFollowingMoves()
            refresh()
        }
    }

    private func stopFollowingMoves() {
        ticker?.stop()
        ticker = nil
        follower.cancel()
    }

    /// The window server's number for the focused window, matched on its
    /// app and its frame; nil when that is not one window exactly.
    private func matchServerNumber() -> CGWindowID? {
        guard let app, let axFrame else { return nil }
        return WindowServerFrame.number(pid: app.pid, frame: axFrame, in: WindowServerFrame.onScreen())
    }

    private func update(_ window: FrontWindow?) {
        guard window != current else { return }
        current = window
        onChange?(window)
    }

    // MARK: - Reading Accessibility

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private static func position(_ element: AXUIElement) -> CGPoint? {
        var point = CGPoint.zero
        guard let value = axValue(element, kAXPositionAttribute), AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(_ element: AXUIElement) -> CGSize? {
        var size = CGSize.zero
        guard let value = axValue(element, kAXSizeAttribute), AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }
}

/// A window's element as `WindowIdentity`'s token: equal for the same window.
private struct WindowToken: Hashable {
    let element: AXUIElement

    static func == (lhs: WindowToken, rhs: WindowToken) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// The observer's callback. Its run loop source is on the main run loop, so
/// this runs on the main thread. `refcon` is the tracker, unretained; the
/// tracker takes the source off the run loop before it goes.
private func frontWindowNotified(_ observer: AXObserver, _ element: AXUIElement,
                                 _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let tracker = Unmanaged<FrontWindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated { tracker.handle(name) }
}

/// Calls `tick` once per frame of a screen, from `start` until `stop`: the
/// display link the tracker runs only while a window moves.
@MainActor private final class DisplayTicker: NSObject {
    private let tick: () -> Void
    private var link: CADisplayLink?

    init(_ tick: @escaping () -> Void) {
        self.tick = tick
        super.init()
    }

    func start(on screen: NSScreen) {
        let link = screen.displayLink(target: self, selector: #selector(fire))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// The link holds its target, so it is let go here.
    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func fire(_ link: CADisplayLink) {
        tick()
    }
}
