import CoreGraphics
import Foundation

/// Which window is in front: its app's process and a token the window tracker
/// makes equal for the same window and different for any other.
struct WindowIdentity: Hashable {
    let pid: pid_t
    let token: AnyHashable

    init(pid: pid_t, token: AnyHashable) {
        self.pid = pid
        self.token = token
    }
}

/// The front window and where it is, in AppKit coordinates (origin at the
/// bottom left of the primary screen). `visibleFrame` is the part of its
/// screen a window can use.
struct FrontWindow: Equatable {
    let id: WindowIdentity
    let frame: CGRect
    let visibleFrame: CGRect
}
