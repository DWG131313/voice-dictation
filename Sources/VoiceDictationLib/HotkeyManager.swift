import Cocoa

/// What the hotkey's event tap tells the app, on the main queue, once it has
/// answered the event. The two cancels differ: `hotkeyCancelled` is the
/// hotkey's own, for this hold only (`cancelHold()`), and
/// `escapePressedWhileWorking` is Escape's, for everything (`cancel()`).
public protocol HotkeyDelegate: AnyObject {
    /// The hotkey went down: a dictation starts recording.
    func hotkeyDidStartPress()
    /// The hotkey was let go after a hold, or double-tapped to stop a
    /// double-tap recording, or its release went by while the tap was off,
    /// or its tap was taken down mid-press: the recording stops and is
    /// transcribed.
    func hotkeyDidEndPress()
    /// A key was pressed while the hotkey was held, or a mouse button while
    /// Right Option or Right Command was, the hotkey used as a modifier:
    /// cancel this hold's dictation, and only that one.
    func hotkeyCancelled()
    /// With double-tap dictation on, the hotkey was tapped rather than held,
    /// maybe the first tap of a double tap: throw away the recording it started.
    func hotkeyDidTap()
    /// A plain Escape, with neither Command, Control nor Option, while the
    /// app was recording, transcribing or cleaning up, locked by a double
    /// tap or not: cancel everything, not just a hold.
    func escapePressedWhileWorking()
    /// Control-Option-V with its shortcut on, once Control and Option are
    /// let go (or a second later, if they stay down): paste the last
    /// transcript.
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

/// The hotkey's event tap, for any `HotkeyChoice` (Task 9's
/// `GlobeKeyStrategy`, generalised in Task 23). It reads the chosen key from
/// modifier changes and judges every key-down and mouse-down, answers each
/// event at once, and tells the delegate afterwards, on the main queue.
/// Every rule is a pure static function (`HotkeyLogic.swift`), tested
/// without a tap; the tap only calls them.
public final class ModifierKeyStrategy: HotkeyStrategy {
    public weak var delegate: HotkeyDelegate?
    /// The key that dictates. Another choice takes another strategy.
    public let choice: HotkeyChoice
    /// Read at each press and release of the hotkey: whether double-tap
    /// dictation is on.
    let doubleTap: () -> Bool
    /// Read at each key-down: whether Control-Option-V pastes the last transcript.
    let pasteLastShortcut: () -> Bool
    /// Read at each event: what the app is doing (`DictationPipeline.state`).
    let appState: () -> DictationState
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The presses, as the tap has seen them; tests set it, never a tap.
    var tracker = TapTracker()
    /// Whether the log has said that an event's timestamp was not trusted.
    private var saidStampUntrusted = false
    /// Paste last's request, while it waits for Control and Option to be let go.
    private var pasteLastWait = PasteLastWait()
    /// How long a Paste last waits at most for Control and Option to be let
    /// go; tests shorten it.
    var pasteLastCap = PasteLastWait.cap
    /// Reads the modifier keys as they are now, for a tap that missed
    /// events: the HID system's state (CGEventSource.h), never an event's.
    /// Tests stand in for it.
    var readLiveFlags: () -> CGEventFlags = {
        ModifierKeyStrategy.liveFlags(flagsState: CGEventSource.flagsState(.hidSystemState),
                                      keyState: { CGEventSource.keyState(.hidSystemState, key: $0) })
    }

    /// The closures are called on the main thread, where the tap runs.
    public init(choice: HotkeyChoice, doubleTap: @escaping () -> Bool = { false },
                pasteLastShortcut: @escaping () -> Bool = { false },
                appState: @escaping () -> DictationState = { .idle }) {
        self.choice = choice
        self.doubleTap = doubleTap
        self.pasteLastShortcut = pasteLastShortcut
        self.appState = appState
    }

    deinit {
        stop()
    }

    // MARK: - The tap

    /// The events the tap sees: modifier changes (the hotkey, and Control
    /// and Option let go for Paste last), key-downs, and every mouse
    /// button's down: a click made with a right-hand hotkey held cancels
    /// that hold, and one during any press of the hotkey makes it no tap.
    static let eventsOfInterest: CGEventMask = [CGEventType.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        .reduce(0) { mask, type in mask | (1 << type.rawValue) }

    /// Makes the tap, or, called again by the health check, a fresh one in
    /// place of a tap that stopped working. The old tap may have missed the
    /// key's release, or a press, so the new one catches up with the key as
    /// it is now: a dictation whose key is still down carries on, and one
    /// whose release was missed stops. If no tap can be made, none will see
    /// the release, and a dictation under way stops as if it had been let go.
    public func start() {
        removeTap()

        Log.info("[HOTKEY] Creating event tap for \(choice.displayName). AXIsProcessTrusted=\(AXIsProcessTrusted())")
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventsOfInterest,
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let strategy = Unmanaged<ModifierKeyStrategy>.fromOpaque(refcon).takeUnretainedValue()
                return strategy.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.info("[HOTKEY] FAILED to create event tap — Accessibility permission may not be granted")
            tell(tracker.reset())
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // Always the main run loop: the callback must run where the delegate lives.
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("[HOTKEY] Event tap created and enabled=\(CGEvent.tapIsEnabled(tap: tap))")
        catchUp()
    }

    /// Takes the tap down for good: listening stops, or another hotkey's tap
    /// replaces this one. The key's release will never be seen, so a
    /// dictation the key held or locked stops as if the key had been let go:
    /// its recording is transcribed, not left running. A Paste last still
    /// waiting for its keys is dropped.
    public func stop() {
        removeTap()
        pasteLastWait.cancel()
        tell(tracker.reset())
    }

    private func removeTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// macOS can disable an event tap (a slow callback, sleep/wake, a change
    /// in Accessibility trust) without telling anyone. Re-enable it, and if
    /// that doesn't stick, tear it down and build a fresh one. Either way the
    /// tap may have missed events meanwhile, and catches up.
    public func ensureHealthy() {
        guard let tap = eventTap else {
            Log.info("[HOTKEY] Health check: no tap present, recreating")
            start()
            return
        }
        if CGEvent.tapIsEnabled(tap: tap) { return }

        Log.info("[HOTKEY] Health check: tap was disabled, re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) {
            catchUp()
        } else {
            Log.info("[HOTKEY] Health check: re-enable failed, recreating tap")
            start()
        }
    }

    /// Answers one event from the tap: the event, to let it through, or nil
    /// to swallow it. Tests call it with events they make and never post.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap whose callback is too slow. Re-enable it, and
        // catch up with the hotkey: its release, or a press, may have gone by.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.info("[HOTKEY] Event tap was disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input") — re-enabling")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            catchUp()
            return Unmanaged.passUnretained(event)
        }

        // Keep this callback fast and quiet: it runs for every modifier change
        // and keystroke on the system, so no logging of routine events here.
        if type == .flagsChanged {
            let flags = event.flags
            tell(Self.action(forFlagsChanged: event.getIntegerValueField(.keyboardEventKeycode), flags: flags,
                             at: time(of: event), choice: choice, tracker: &tracker,
                             doubleTap: doubleTap(), state: appState()))
            if pasteLastWait.modifiersChanged(to: flags) {
                deliver { $0.pasteLastShortcutPressed() }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let action = Self.action(forKeyDown: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags,
                                     isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                     sourceUserData: event.getIntegerValueField(.eventSourceUserData), choice: choice,
                                     tracker: &tracker, state: appState(), pasteLastShortcut: pasteLastShortcut())
            tell(action)
            if action.consumes {
                return nil
            }
        }

        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            tell(Self.action(forMouseDownWithUserData: event.getIntegerValueField(.eventSourceUserData), choice: choice,
                             tracker: &tracker))
        }

        return Unmanaged.passUnretained(event)
    }

    /// The tap missed events: macOS had it turned off, or it was rebuilt.
    /// Catches up with the hotkey as it is now, from the live modifier state.
    private func catchUp() {
        tell(Self.action(forLiveFlags: readLiveFlags(), choice: choice, tracker: &tracker))
    }

    /// When `event` happened, by its own timestamp (`eventTime`), so a press
    /// handled late is timed as it was made; by the moment it is handled
    /// when the stamp cannot be trusted, which the log says once.
    private func time(of event: CGEvent) -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        if let time = Self.eventTime(stampedAt: event.timestamp, handledAt: now) { return time }
        if !saidStampUntrusted {
            saidStampUntrusted = true
            Log.info("[HOTKEY] An event's timestamp (\(event.timestamp)) is not on the uptime clock (\(now) s); "
                     + "timing presses by when they are handled")
        }
        return now
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
        case .pasteLastAndConsume: waitToPasteLast()
        case .none, .consume: break
        }
    }

    /// Paste last's shortcut: the paste waits for Control and Option to be
    /// let go, which `handle` sees as a modifier change, and goes anyway
    /// after `pasteLastCap` (Ruling T23-1).
    private func waitToPasteLast() {
        let request = pasteLastWait.request()
        let cap = pasteLastCap
        DispatchQueue.main.asyncAfter(deadline: .now() + cap) { [weak self] in
            guard let self, self.pasteLastWait.capReached(for: request) else { return }
            Log.info("[HOTKEY] Paste last: Control or Option still down after \(cap) s; pasting anyway")
            self.deliver { $0.pasteLastShortcutPressed() }
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

/// What the app asks of `HotkeyManager`: listen with a strategy, which
/// replaces one already running, and stop. The app takes it through this, so
/// tests stand in for it and no event tap is ever made (Task 24).
public protocol HotkeyListening: AnyObject {
    var delegate: HotkeyDelegate? { get set }
    /// Starts listening with `strategy`; called again, it replaces the one
    /// running.
    func start(strategy: HotkeyStrategy?)
    func stop()
}

extension HotkeyManager: HotkeyListening {}

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
