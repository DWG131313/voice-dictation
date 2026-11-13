import Cocoa
import Carbon.HIToolbox
import IOKit.hidsystem

/// The key held to dictate (Task 23). Globe is the default; the right-hand
/// Option and Command keys suit a keyboard whose Globe key does something
/// else, and leave the left-hand ones free for shortcuts.
public enum HotkeyChoice: String, Codable, CaseIterable, Sendable {
    case globe, rightOption, rightCommand

    /// How the window and the logs name the key.
    public var displayName: String {
        switch self {
        case .globe: return "Globe"
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        }
    }

    /// What a `flagsChanged` event says about this key: whether it is now
    /// down, or nil when the event is about another key.
    ///
    /// Globe is read as before Task 23, from the Fn flag of every modifier
    /// change: Globe+Shift reports Globe down again, which changes nothing.
    /// A right-hand key is read only from its own key's events (Events.h:
    /// `kVK_RightOption` is 61, `kVK_RightCommand` 54), by the
    /// device-dependent bit IOLLEvent.h gives that side
    /// (`NX_DEVICERALTKEYMASK`, `NX_DEVICERCMDKEYMASK`). So the left-hand key
    /// (58, 55), which sets the same Option or Command flag, does nothing,
    /// and letting go of the right-hand one ends the dictation even while the
    /// left one is still down.
    func isDown(flagsChangedKeyCode keyCode: Int64, flags: CGEventFlags) -> Bool? {
        switch self {
        case .globe:
            return flags.contains(.maskSecondaryFn)
        case .rightOption:
            guard keyCode == Int64(kVK_RightOption) else { return nil }
            return flags.rawValue & UInt64(NX_DEVICERALTKEYMASK) != 0
        case .rightCommand:
            guard keyCode == Int64(kVK_RightCommand) else { return nil }
            return flags.rawValue & UInt64(NX_DEVICERCMDKEYMASK) != 0
        }
    }
}

/// What a press or release of the hotkey does to the dictation.
public enum HotkeyAction: Equatable {
    /// Nothing: a down while the key is already down, a release after a
    /// cancel, or the release of the press that stopped a hands-free
    /// recording, or of the second tap that locked one.
    case none
    /// A recording starts.
    case start
    /// The recording stops and is transcribed.
    case stop
    /// The press was a tap with hands-free on, maybe the first of a double
    /// tap: its recording is thrown away.
    case discardTap
}

/// The hotkey's presses and releases, turned into what they do to the
/// dictation (Task 23), kept apart from the event tap so the rules can be
/// tested.
///
/// Hands-free off, every press records and its release stops, as before: a
/// quick tap makes a recording too short to keep, which the recorder's
/// 0.5 s rule throws away. Hands-free on, a hold dictates the same way. A
/// tap, a press let go within `tapMaximum`, is no dictation: its recording
/// is thrown away (`.discardTap`). A second tap that goes down within
/// `doubleTapWindow` of the first one's release locks instead: its recording
/// carries on after it is let go, until the next press stops it.
public struct TapTracker {
    public static let doubleTapWindow: TimeInterval = 0.35, tapMaximum: TimeInterval = 0.25

    /// Where the hotkey stands for the dictation.
    enum Hold: Equatable {
        /// Up, or down only to stop a hands-free recording, or down for a
        /// dictation a key has cancelled.
        case none
        /// Down for the dictation its press started.
        case held
        /// Up, with a hands-free recording running until the next press.
        case locked
    }

    /// Read at each release. The event tap sets it from the preference at
    /// each press and release, so a change takes effect at once.
    public var handsFreeEnabled: Bool
    /// Whether the key is down, as last reported.
    private var isDown = false
    /// When the press under way went down, while it holds the dictation it
    /// started.
    private var heldSince: TimeInterval?
    private var isLocked = false
    /// When the last tap was let go, while a second one could still lock.
    private var lastTapEnd: TimeInterval?

    public init(handsFreeEnabled: Bool = false) {
        self.handsFreeEnabled = handsFreeEnabled
    }

    var hold: Hold {
        if isLocked { return .locked }
        return heldSince == nil ? .none : .held
    }

    /// The key went down at `time`, in seconds on a steady clock. A down
    /// while it is already down changes nothing.
    public mutating func down(at time: TimeInterval) -> HotkeyAction {
        guard !isDown else { return .none }
        isDown = true
        if isLocked {
            isLocked = false
            return .stop
        }
        heldSince = time
        return .start
    }

    /// The key went up at `time`. An up while it is up changes nothing.
    public mutating func up(at time: TimeInterval) -> HotkeyAction {
        guard isDown else { return .none }
        isDown = false
        guard let start = heldSince else { return .none }
        heldSince = nil
        guard handsFreeEnabled, time - start <= Self.tapMaximum else {
            lastTapEnd = nil
            return .stop
        }
        if let lastTapEnd, start - lastTapEnd <= Self.doubleTapWindow {
            self.lastTapEnd = nil
            isLocked = true
            return .none
        }
        lastTapEnd = time
        return .discardTap
    }

    /// The dictation the hotkey held or locked is over: a key cancelled the
    /// hold, Escape cancelled everything, or the hands-free recording ended
    /// by itself. The key's release, or its next press, starts from nothing.
    mutating func cancel() {
        heldSince = nil
        isLocked = false
        lastTapEnd = nil
    }

    /// Forgets every press, for an event tap that is rebuilt: the new tap may
    /// never see the key's release. Returns `.stop` when a dictation was held
    /// or locked, to end it as if the key had been let go; a release that
    /// does arrive afterwards changes nothing.
    mutating func reset() -> HotkeyAction {
        let wasDictating = hold != .none
        cancel()
        isDown = false
        return wasDictating ? .stop : .none
    }
}

/// What the hotkey's event tap tells the app, on the main queue, once it has
/// answered the event. The two cancels differ: `hotkeyCancelled` is the
/// hotkey's own, for this hold only (`cancelHold()`), and
/// `escapePressedWhileWorking` is Escape's, for everything (`cancel()`).
public protocol HotkeyDelegate: AnyObject {
    /// The hotkey went down: a dictation starts recording.
    func hotkeyDidStartPress()
    /// The hotkey was let go after a hold, or pressed to stop a hands-free
    /// recording, or its tap was rebuilt or replaced mid-press: the
    /// recording stops and is transcribed.
    func hotkeyDidEndPress()
    /// A key was pressed while the hotkey was held, the hotkey used as a
    /// modifier: cancel this hold's dictation, and only that one.
    func hotkeyCancelled()
    /// With hands-free on, the hotkey was tapped rather than held, maybe the
    /// first tap of a double tap: throw away the recording it started.
    func hotkeyDidTap()
    /// Escape while the app was recording, transcribing or cleaning up,
    /// hands-free locked or not: cancel everything, not just a hold.
    func escapePressedWhileWorking()
    /// Control-Option-V with its shortcut on: paste the last transcript.
    func pasteLastShortcutPressed()
}

public protocol HotkeyStrategy: AnyObject {
    var delegate: HotkeyDelegate? { get set }
    func start()
    func stop()
    /// Called periodically and after sleep/wake. Implementations should
    /// verify they are still receiving events and repair themselves if not.
    func ensureHealthy()
}

/// How the event tap answers a key-down: what it does to the dictation, and
/// whether the key goes on to the app in front.
public enum KeyAction: Equatable, Sendable {
    /// Nothing happens and the key goes through untouched. That is any key
    /// while the hotkey is up and the app is not working, any key but Escape
    /// while hands-free is locked, Control-Option-V with its shortcut off,
    /// and the app's own Cmd+V, tagged `PasteEngine.eventTag` (a dictation's
    /// paste, or Paste last's), whatever the hotkey, the hold or the state.
    case none
    /// Another key while the hotkey is held for a dictation: the hotkey was
    /// used as a modifier (Globe+Right Arrow is End), so this hold's
    /// dictation is cancelled with `cancelHold()`, which never reaches an
    /// earlier one, and the key goes through.
    case cancelHoldAndPass
    /// Escape while the app is working (recording, transcribing or cleaning
    /// up), whether the hotkey is held, locked or up: everything is cancelled
    /// with `cancel()`, and Escape is swallowed.
    case cancelAllAndConsume
    /// Control-Option-V with its shortcut on: the last transcript pastes
    /// (`pasteLast()`), and the key is swallowed.
    case pasteLastAndConsume
    /// A key repeat of either of the two above, the key held down: swallowed,
    /// and nothing more happens. A held Escape cancels once, and a held
    /// Control-Option-V pastes once.
    case consume

    /// Whether the key is swallowed rather than going on to the app.
    var consumes: Bool {
        switch self {
        case .none, .cancelHoldAndPass: return false
        case .cancelAllAndConsume, .pasteLastAndConsume, .consume: return true
        }
    }
}

/// The hotkey's event tap, for any `HotkeyChoice` (Task 9's
/// `GlobeKeyStrategy`, generalised in Task 23). It reads the chosen key from
/// modifier changes and judges every key-down, answers each event at once,
/// and tells the delegate afterwards, on the main queue. Every rule is a
/// pure static function, tested without a tap; the tap only calls them.
public final class ModifierKeyStrategy: HotkeyStrategy {
    public weak var delegate: HotkeyDelegate?
    /// The key that dictates. Another choice takes another strategy.
    public let choice: HotkeyChoice
    /// Read at each press and release of the hotkey: whether hands-free is on.
    let handsFree: () -> Bool
    /// Read at each key-down: whether Control-Option-V pastes the last transcript.
    let pasteLastShortcut: () -> Bool
    /// Read at each event: what the app is doing (`DictationPipeline.state`).
    let appState: () -> DictationState
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The presses, as the tap has seen them; tests set it, never a tap.
    var tracker = TapTracker()

    /// The closures are called on the main thread, where the tap runs.
    public init(choice: HotkeyChoice, handsFree: @escaping () -> Bool = { false },
                pasteLastShortcut: @escaping () -> Bool = { false },
                appState: @escaping () -> DictationState = { .idle }) {
        self.choice = choice
        self.handsFree = handsFree
        self.pasteLastShortcut = pasteLastShortcut
        self.appState = appState
    }

    deinit {
        stop()
    }

    // MARK: - The rules

    /// How the tap answers a modifier change: nothing unless it is about the
    /// chosen key (`HotkeyChoice.isDown`), then the tracker's answer. A
    /// hands-free recording that ended by itself (five minutes, an input
    /// change, a failure) leaves no lock: the press after it dictates,
    /// rather than stopping a recording that is already over.
    static func action(forFlagsChanged keyCode: Int64, flags: CGEventFlags, at time: TimeInterval, choice: HotkeyChoice,
                       tracker: inout TapTracker, handsFree: Bool = false, state: DictationState) -> HotkeyAction {
        guard let isDown = choice.isDown(flagsChangedKeyCode: keyCode, flags: flags) else { return .none }
        tracker.handsFreeEnabled = handsFree
        guard isDown else { return tracker.up(at: time) }
        if tracker.hold == .locked, !isRecording(state) { tracker.cancel() }
        return tracker.down(at: time)
    }

    /// How the tap answers a key-down, given where the hotkey stands and what
    /// the app is doing: Task 9's decision, extended with the state. In
    /// order: the app's own Cmd+V goes through untouched; Escape cancels
    /// everything while the app works, and is swallowed only then; any key
    /// while the hotkey is held cancels that hold, Control-Option-V included;
    /// Control-Option-V with its shortcut on pastes the last transcript. A
    /// key repeat never cancels or pastes again.
    static func action(forKeyDown keyCode: Int64, flags: CGEventFlags = [], isRepeat: Bool = false,
                       sourceUserData: Int64 = 0, hold: TapTracker.Hold, state: DictationState,
                       pasteLastShortcut: Bool = false) -> KeyAction {
        guard sourceUserData != PasteEngine.eventTag else { return .none }
        if keyCode == Int64(kVK_Escape), isWorking(state) {
            return isRepeat ? .consume : .cancelAllAndConsume
        }
        if hold == .held { return .cancelHoldAndPass }
        if pasteLastShortcut, keyCode == Int64(kVK_ANSI_V), isControlOption(flags) {
            return isRepeat ? .consume : .pasteLastAndConsume
        }
        return .none
    }

    /// The same, applied to `tracker`: a cancel ends the hotkey's hold or
    /// its hands-free lock, so the key's release, or its next press, starts
    /// from nothing.
    static func action(forKeyDown keyCode: Int64, flags: CGEventFlags = [], isRepeat: Bool = false,
                       sourceUserData: Int64 = 0, tracker: inout TapTracker, state: DictationState,
                       pasteLastShortcut: Bool = false) -> KeyAction {
        let answer = Self.action(forKeyDown: keyCode, flags: flags, isRepeat: isRepeat, sourceUserData: sourceUserData,
                                 hold: tracker.hold, state: state, pasteLastShortcut: pasteLastShortcut)
        switch answer {
        case .cancelHoldAndPass, .cancelAllAndConsume: tracker.cancel()
        case .none, .pasteLastAndConsume, .consume: break
        }
        return answer
    }

    /// Escape cancels: something is being recorded, transcribed or cleaned up.
    private static func isWorking(_ state: DictationState) -> Bool {
        switch state {
        case .recording, .transcribing, .cleaning: return true
        case .idle, .preparingModel, .needsPermission, .error: return false
        }
    }

    private static func isRecording(_ state: DictationState) -> Bool {
        if case .recording = state { return true }
        return false
    }

    /// Control and Option without Command or Shift; Caps Lock and Fn do not
    /// matter.
    private static func isControlOption(_ flags: CGEventFlags) -> Bool {
        flags.contains([.maskControl, .maskAlternate]) && flags.isDisjoint(with: [.maskCommand, .maskShift])
    }

    // MARK: - The tap

    public func start() {
        stop()

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        Log.info("[HOTKEY] Creating event tap for \(choice.displayName). AXIsProcessTrusted=\(AXIsProcessTrusted())")
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let strategy = Unmanaged<ModifierKeyStrategy>.fromOpaque(refcon).takeUnretainedValue()
                return strategy.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.info("[HOTKEY] FAILED to create event tap — Accessibility permission may not be granted")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // Always the main run loop: the callback must run where the delegate lives.
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("[HOTKEY] Event tap created and enabled=\(CGEvent.tapIsEnabled(tap: tap))")
    }

    /// Takes the tap down. The key's release may then never be seen, by this
    /// tap or by the one that replaces it (the health check's rebuild, or
    /// another hotkey), so a dictation the key held or locked stops as if the
    /// key had been let go: its recording is transcribed, not left running.
    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        tell(tracker.reset())
    }

    /// macOS can disable an event tap (a slow callback, sleep/wake, a change
    /// in Accessibility trust) without telling anyone. Re-enable it, and if
    /// that doesn't stick, tear it down and build a fresh one.
    public func ensureHealthy() {
        guard let tap = eventTap else {
            Log.info("[HOTKEY] Health check: no tap present, recreating")
            start()
            return
        }
        if CGEvent.tapIsEnabled(tap: tap) { return }

        Log.info("[HOTKEY] Health check: tap was disabled, re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
        if !CGEvent.tapIsEnabled(tap: tap) {
            Log.info("[HOTKEY] Health check: re-enable failed, recreating tap")
            start()
        }
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap whose callback is too slow. Re-enable and move on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.info("[HOTKEY] Event tap was disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input") — re-enabling")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Keep this callback fast and quiet: it runs for every modifier change
        // and keystroke on the system, so no logging of routine events here.
        if type == .flagsChanged {
            tell(Self.action(forFlagsChanged: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags,
                             at: ProcessInfo.processInfo.systemUptime, choice: choice, tracker: &tracker,
                             handsFree: handsFree(), state: appState()))
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let action = Self.action(forKeyDown: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags,
                                     isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                     sourceUserData: event.getIntegerValueField(.eventSourceUserData),
                                     tracker: &tracker, state: appState(), pasteLastShortcut: pasteLastShortcut())
            tell(action)
            if action.consumes {
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Telling the app

    private func tell(_ action: HotkeyAction) {
        switch action {
        case .start: deliver { $0.hotkeyDidStartPress() }
        case .stop: deliver { $0.hotkeyDidEndPress() }
        case .discardTap: deliver { $0.hotkeyDidTap() }
        case .none: break
        }
    }

    private func tell(_ action: KeyAction) {
        switch action {
        case .cancelHoldAndPass: deliver { $0.hotkeyCancelled() }
        case .cancelAllAndConsume: deliver { $0.escapePressedWhileWorking() }
        case .pasteLastAndConsume: deliver { $0.pasteLastShortcutPressed() }
        case .none, .consume: break
        }
    }

    /// Calls the delegate on the main queue, once the tap has answered, so
    /// the callback stays short. The delegate is taken now, so a strategy
    /// torn down meanwhile still delivers what it decided as it stopped.
    private func deliver(_ message: @escaping (HotkeyDelegate) -> Void) {
        guard let delegate else { return }
        DispatchQueue.main.async { message(delegate) }
    }
}

public class HotkeyManager {
    public weak var delegate: HotkeyDelegate? {
        didSet { strategy?.delegate = delegate }
    }
    private var strategy: HotkeyStrategy?
    private var healthTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    public init() {}

    deinit { stop() }

    public private(set) var isRunning = false

    /// Starts listening with `strategy`, the Globe key's when nil. Called
    /// again, with another hotkey's strategy say, it replaces the one
    /// running: that one stops first, and a dictation its key held or locked
    /// ends as if the key had been let go.
    public func start(strategy: HotkeyStrategy? = nil) {
        self.strategy?.stop()
        self.strategy = strategy ?? ModifierKeyStrategy(choice: .globe)
        self.strategy?.delegate = delegate
        self.strategy?.start()
        isRunning = true

        // Periodic self-check plus an explicit check after wake, when taps
        // most often go quiet.
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.strategy?.ensureHealthy()
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Log.info("[HOTKEY] System woke — checking event tap")
                self?.strategy?.ensureHealthy()
            }
        }
    }

    public func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
        strategy?.stop()
        isRunning = false
    }
}
