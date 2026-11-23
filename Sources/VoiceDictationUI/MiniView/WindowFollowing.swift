import ApplicationServices
import CoreGraphics

/// Keeps the tab with a window while it moves. macOS reports a dragged
/// window's moves only about 9 times a second, in every app (measured on
/// 2026-11-22), so a tab moved only on those reports jumps along behind the
/// window. While one is moving, the tracker reads the window's frame every
/// screen frame through this, and stops once the window has been still for
/// `stillness`, so nothing runs while no window moves.
struct MoveFollower {
    /// Longer than macOS's gap between move reports (about 0.12 s), so a
    /// window still being dragged is not let go between them.
    static let stillness: TimeInterval = 0.3

    enum Tick: Equatable {
        /// The window is somewhere new: the tab goes with it.
        case moved(CGRect)
        /// No change this frame.
        case still
        /// Following is over: still for long enough, or the window can't be read.
        case stop
    }

    private(set) var isFollowing = false
    private var lastFrame: CGRect?
    private var lastChange: TimeInterval = 0

    /// A move or resize report, with the frame just read: follow from here.
    mutating func reported(_ frame: CGRect, at now: TimeInterval) {
        isFollowing = true
        lastFrame = frame
        lastChange = now
    }

    /// One screen frame, with the window's frame now, nil when it can't be read.
    mutating func tick(_ frame: CGRect?, at now: TimeInterval) -> Tick {
        guard isFollowing else { return .stop }
        guard let frame else {
            cancel()
            return .stop
        }
        if frame != lastFrame {
            lastFrame = frame
            lastChange = now
            return .moved(frame)
        }
        guard now - lastChange < Self.stillness else {
            cancel()
            return .stop
        }
        return .still
    }

    mutating func cancel() {
        isFollowing = false
        lastFrame = nil
    }
}

/// The window server's own record of a window: its bounds, current even mid
/// drag, when Accessibility's reported position can trail it by up to 190 pt
/// (measured). Bounds and owner only; never a title, which would need
/// Screen Recording.
enum WindowServerFrame {
    /// The number of `pid`'s window at `frame`, in top-left coordinates as
    /// Accessibility gives them, from a `CGWindowListCopyWindowInfo` list.
    /// Nil when none matches, or more than one: following the wrong window
    /// would be worse than following none.
    static func number(pid: pid_t, frame: CGRect, in list: [[String: Any]]) -> CGWindowID? {
        let matches = list.compactMap { info -> CGWindowID? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = bounds(info), close(bounds, frame) else { return nil }
            return number
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The bounds of every on-screen window, for `number(pid:frame:in:)`.
    static func onScreen() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
    }

    /// The window's bounds now, in top-left coordinates; nil once it is gone.
    static func frame(of number: CGWindowID) -> CGRect? {
        let list = CGWindowListCreateDescriptionFromArray([NSNumber(value: number)] as CFArray) as? [[String: Any]]
        return list?.first.flatMap(bounds)
    }

    private static func bounds(_ info: [String: Any]) -> CGRect? {
        guard let dictionary = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary)
    }

    /// Accessibility and the window server can differ by a fraction of a point.
    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
}

/// Following an app that has only just launched can fail for a moment: it is
/// too busy to answer Accessibility (`cannotComplete`), as Safari was on its
/// first launch on 2026-11-22, and its window had no tab until it was brought
/// to the front again. Such an app is tried again, a few times.
struct FollowRetry {
    static let delay: Duration = .milliseconds(500)
    static let attempts = 10

    private var failures = 0

    /// The wait before trying again, or nil to give up.
    mutating func failed(_ error: AXError) -> Duration? {
        guard error == .cannotComplete, failures < Self.attempts else { return nil }
        failures += 1
        return Self.delay
    }

    /// Following worked, or another app came to the front.
    mutating func reset() {
        failures = 0
    }
}
