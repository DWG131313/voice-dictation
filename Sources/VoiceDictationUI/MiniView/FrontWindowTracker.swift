import AppKit
import ApplicationServices
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
/// through one `AXObserver`: macOS's notifications, never a timer. It reads
/// only a window's subrole, full-screen and minimised state, position and
/// size; never its title or contents. Without Accessibility, `current` stays
/// nil. VoiceDictation's own windows are not followed.
@MainActor final class FrontWindowTracker: FrontWindowWatching {
    var onChange: ((FrontWindow?) -> Void)?
    private(set) var current: FrontWindow?

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

    /// How long one Accessibility call to the front app may wait, in seconds.
    /// These calls run on the main thread, where the hotkey's event tap runs
    /// too; a hung app must not hold it for the default 6 s. Set per element:
    /// a window's element does not take it from its app's.
    private static let messagingTimeout: Float = 0.25

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
        unfollowApp()
        current = nil
    }

    /// From the observer's callback, on the main thread.
    fileprivate func handle(_ notification: String) {
        guard app != nil else { return }
        switch notification {
        case kAXFocusedWindowChangedNotification, kAXUIElementDestroyedNotification:
            focusChanged()
        default:
            refresh()
        }
    }

    // MARK: - Following

    /// The app now in front: a new observer for a new app, a fresh read of
    /// the same one.
    private func follow(pid: pid_t?) {
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier, AXIsProcessTrusted() else {
            unfollowApp()
            update(nil)
            return
        }
        if app?.pid != pid {
            unfollowApp()
            app = Self.observe(pid: pid, refcon: Unmanaged.passUnretained(self).toOpaque())
        }
        focusChanged()
    }

    private static func observe(pid: pid_t, refcon: UnsafeMutableRawPointer) -> FollowedApp? {
        var created: AXObserver?
        guard AXObserverCreate(pid, frontWindowNotified, &created) == .success, let observer = created else {
            return nil
        }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        let added = AXObserverAddNotification(observer, element, kAXFocusedWindowChangedNotification as CFString, refcon)
        guard added == .success else {
            Log.info("[MINI] Cannot follow the front app's windows (AXError \(added.rawValue))")
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        return FollowedApp(pid: pid, element: element, observer: observer)
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
    }

    private func unwatchWindow() {
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
            update(nil)
            return
        }
        let frame = MiniViewLayout.appKitFrame(axPosition: position, axSize: size,
                                               primaryScreenHeight: primary.frame.height)
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(centre) } ?? primary
        update(FrontWindow(id: WindowIdentity(pid: app.pid, token: WindowToken(element: window)),
                           frame: frame, visibleFrame: screen.visibleFrame))
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
