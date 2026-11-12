/// What `AppLifecycle` needs to know about a window to decide whether it
/// still counts as one the user has open.
struct WindowSnapshot: Equatable {
    var isVisible: Bool
    var canBecomeMain: Bool
}

/// The app is a menu bar app that gets a Dock icon only while a window is
/// open. This decides what happens when one closes.
enum WindowPolicy {
    enum AfterClose: Equatable {
        /// Another window is open: leave the Dock icon and focus alone.
        case stayRegular
        /// That was the last: back to the menu bar only, and hide so focus
        /// returns to the app that was in front.
        case leaveAndHide
    }

    /// `windows` are the app's windows once the closing one has gone. The
    /// menu bar menu's panel cannot become main, so it never counts.
    static func afterClose(windows: [WindowSnapshot]) -> AfterClose {
        windows.contains { $0.isVisible && $0.canBecomeMain } ? .stayRegular : .leaveAndHide
    }
}
