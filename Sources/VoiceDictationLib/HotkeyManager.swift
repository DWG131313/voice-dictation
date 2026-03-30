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
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        print("[HOTKEY] Creating event tap... AXIsProcessTrusted=\(AXIsProcessTrusted())")
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
            print("[HOTKEY] FAILED to create event tap — Accessibility permission may not be granted")
            return
        }
        print("[HOTKEY] Event tap created successfully")

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // Use main run loop explicitly — CFRunLoopGetCurrent() may not be the main one
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[HOTKEY] Tap enabled on MAIN run loop. tapEnabled=\(CGEvent.tapIsEnabled(tap: tap))")
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isPressed = false
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Log tap disable events (macOS can disable taps)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("[HOTKEY] Event tap was DISABLED by \(type == .tapDisabledByTimeout ? "timeout" : "user input") — re-enabling")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            let flags = event.flags
            let rawFlags = event.flags.rawValue
            let fnPressed = flags.contains(.maskSecondaryFn)
            print("[HOTKEY] flagsChanged: fn=\(fnPressed) rawFlags=\(rawFlags) isPressed=\(isPressed)")

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
        }

        // Check for Escape key to cancel during recording
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            print("[HOTKEY] keyDown: keyCode=\(keyCode)")
            if keyCode == Int64(kVK_Escape) && isPressed {
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

    public init() {}

    public func start(strategy: HotkeyStrategy? = nil) {
        self.strategy = strategy ?? GlobeKeyStrategy()
        self.strategy?.delegate = delegate
        self.strategy?.start()
    }

    public func stop() {
        strategy?.stop()
    }
}
