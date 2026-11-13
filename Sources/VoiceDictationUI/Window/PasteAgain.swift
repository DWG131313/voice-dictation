import AppKit

// Paste again (Ruling T19-3): the pure decision `LibraryModel.pasteAgain`
// makes at each look, and the macOS side it looks through.

extension LibraryModel {
    /// One look at the apps while Paste again waits (Ruling T19-3).
    enum PasteAgainStep: Equatable {
        /// The app that was in front before this one is in front again.
        case paste
        /// It is not yet.
        case wait
        /// There is none, or it has not come back in time: copy instead, so
        /// nothing pastes into the wrong app.
        case copyInstead
    }

    /// Whether Paste again may paste now: only into `target`, the app that
    /// was in front before this one, and only once it is in front again.
    /// After waiting `limit` seconds for it, Paste again copies instead.
    nonisolated static func pasteAgainStep(target: pid_t?, frontmost: pid_t?, waited: TimeInterval,
                                           limit: TimeInterval) -> PasteAgainStep {
        guard let target else { return .copyInstead }
        if frontmost == target { return .paste }
        return waited < limit ? .wait : .copyInstead
    }
}

/// What Paste again needs from macOS, so tests can stand in for it: the app
/// that was in front before this one, the app in front now, and hiding and
/// showing this app's windows. Process identifiers name the apps.
struct PasteAgainSystem {
    var previousApp: @MainActor () -> pid_t?
    var frontmostApp: @MainActor () -> pid_t?
    var hide: @MainActor () -> Void
    var unhide: @MainActor () -> Void

    /// macOS itself. The previous app is the last other app to become
    /// active, which macOS announces for every app; one that has quit counts
    /// as none. Hiding hands the front back to it, as closing the last window
    /// does (`AppLifecycle.windowDidClose`). Showing the windows again does
    /// not activate the app (`unhideWithoutActivation`), so whichever app came
    /// to the front meanwhile keeps the keyboard. `application` hides and
    /// shows them: a test's stand-in, or by default this app's `NSApplication`.
    @MainActor
    static func live(application: AppHiding? = nil) -> PasteAgainSystem {
        let application = application ?? NSApplication.shared
        let tracker = PreviousAppTracker()
        return PasteAgainSystem(
            previousApp: { tracker.previous.flatMap { $0.isTerminated ? nil : $0.processIdentifier } },
            frontmostApp: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            hide: { application.hide(nil) },
            unhide: { application.unhideWithoutActivation() }
        )
    }
}

/// What hides and shows this app's windows for Paste again: `NSApplication`,
/// or a test's stand-in, which hides nothing. It shows them only without
/// activating the app: `unhide(_:)` would take the keyboard from the app in
/// front.
@MainActor
protocol AppHiding: AnyObject {
    func hide(_ sender: Any?)
    func unhideWithoutActivation()
}

extension NSApplication: AppHiding {}

/// Remembers the last app other than this one to become active.
private final class PreviousAppTracker {
    private(set) var previous: NSRunningApplication?
    private var observer: NSObjectProtocol?

    init() {
        let thisApp = NSRunningApplication.current.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != thisApp {
            previous = front
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != thisApp else { return }
            self?.previous = app
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
