import Cocoa
import Carbon.HIToolbox

public protocol HotkeyDelegate: AnyObject {
    func hotkeyDidStartPress()
    func hotkeyDidEndPress()
    /// A key was pressed while the hotkey was held: cancel this hold's
    /// dictation, and only that one.
    func hotkeyCancelled()
}

public protocol HotkeyStrategy: AnyObject {
    var delegate: HotkeyDelegate? { get set }
    func start()
    func stop()
    /// Called periodically and after sleep/wake. Implementations should
    /// verify they are still receiving events and repair themselves if not.
    func ensureHealthy()
}

/// What a key pressed while Globe is held does to the dictation.
public enum KeyAction: Equatable, Sendable {
    /// Globe is not held for a dictation: the key goes through untouched.
    case none
    /// Escape: the dictation is cancelled and the key is swallowed.
    case cancelAndConsume
    /// Any other key, as when Globe is a modifier (Globe+Right Arrow is
    /// End): the dictation is cancelled and the key goes through.
    case cancelAndPass
}

/// The Globe key's presses, one event at a time, kept apart from the event
/// tap so the rules can be tested.
struct GlobeKeyPresses {
    enum Press: Equatable { case none, start, end }

    /// Whether Globe is held for a dictation.
    private(set) var isPressed = false
    /// A key cancelled this hold's dictation. Globe then starts nothing more
    /// until it is released: any modifier change while it is still down
    /// (Shift let go after Globe+Shift+Right Arrow) reports it down again.
    private var cancelledThisHold = false

    /// The Globe key's flag in a modifier change.
    mutating func globeChanged(isDown: Bool) -> Press {
        defer { if !isDown { cancelledThisHold = false } }
        if isDown, !isPressed, !cancelledThisHold {
            isPressed = true
            return .start
        }
        if !isDown, isPressed {
            isPressed = false
            return .end
        }
        return .none
    }

    mutating func keyDown(_ keyCode: Int64) -> KeyAction {
        let action = GlobeKeyStrategy.action(forKeyDown: keyCode, whilePressed: isPressed)
        if action != .none {
            isPressed = false
            cancelledThisHold = true
        }
        return action
    }

    mutating func reset() {
        isPressed = false
        cancelledThisHold = false
    }
}

public class GlobeKeyStrategy: HotkeyStrategy {
    public weak var delegate: HotkeyDelegate?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var presses = GlobeKeyPresses()

    /// A key pressed while Globe is held for a dictation cancels it, so
    /// using Globe as a modifier never dictates. Escape is swallowed; any
    /// other key goes through to the app.
    public static func action(forKeyDown keyCode: Int64, whilePressed: Bool) -> KeyAction {
        guard whilePressed else { return .none }
        return keyCode == Int64(kVK_Escape) ? .cancelAndConsume : .cancelAndPass
    }

    /// How the tap answers a key-down; `sourceUserData` is the event's
    /// `.eventSourceUserData`. The pipeline pastes an earlier dictation as
    /// soon as its text is ready, maybe while Globe is held for the next one,
    /// and the tap sees that Cmd+V too. `PasteEngine` tags it with
    /// `PasteEngine.eventTag`, so it goes through without consulting
    /// `presses`: the app's own keystroke never cancels. Any other key is
    /// the press's to judge.
    static func action(forKeyDown keyCode: Int64, sourceUserData: Int64, presses: inout GlobeKeyPresses) -> KeyAction {
        guard sourceUserData != PasteEngine.eventTag else { return .none }
        return presses.keyDown(keyCode)
    }

    public init() {}

    deinit {
        stop()
    }

    public func start() {
        stop()

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        Log.info("[HOTKEY] Creating event tap. AXIsProcessTrusted=\(AXIsProcessTrusted())")
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let strategy = Unmanaged<GlobeKeyStrategy>.fromOpaque(refcon).takeUnretainedValue()
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
        presses.reset()
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
            switch presses.globeChanged(isDown: event.flags.contains(.maskSecondaryFn)) {
            case .start:
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.hotkeyDidStartPress()
                }
            case .end:
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.hotkeyDidEndPress()
                }
            case .none:
                break
            }
            return Unmanaged.passUnretained(event)
        }

        // Any key pressed while holding the Globe key cancels this hold's
        // dictation; the app's own Cmd+V never does.
        if type == .keyDown {
            let action = Self.action(forKeyDown: event.getIntegerValueField(.keyboardEventKeycode),
                                     sourceUserData: event.getIntegerValueField(.eventSourceUserData),
                                     presses: &presses)
            if action != .none {
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.hotkeyCancelled()
                }
            }
            if action == .cancelAndConsume {
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
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

    public func start(strategy: HotkeyStrategy? = nil) {
        self.strategy = strategy ?? GlobeKeyStrategy()
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
