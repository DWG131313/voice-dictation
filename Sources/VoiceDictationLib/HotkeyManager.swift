import Cocoa
import Carbon.HIToolbox

public protocol HotkeyDelegate: AnyObject {
    func hotkeyDidStartPress()
    func hotkeyDidEndPress()
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

public class GlobeKeyStrategy: HotkeyStrategy {
    public weak var delegate: HotkeyDelegate?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

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
        isPressed = false
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
            let fnPressed = event.flags.contains(.maskSecondaryFn)

            if fnPressed && !isPressed {
                isPressed = true
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.hotkeyDidStartPress()
                }
            } else if !fnPressed && isPressed {
                isPressed = false
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.hotkeyDidEndPress()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Escape while holding the Globe key cancels the recording.
        if type == .keyDown && isPressed {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Int64(kVK_Escape) {
                isPressed = false
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.hotkeyCancelled()
                }
                return nil // Consume the Escape event
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
