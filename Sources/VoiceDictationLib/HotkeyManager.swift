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
            print("Failed to create event tap — Accessibility permission may not be granted")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
        if type == .flagsChanged {
            let flags = event.flags
            let fnPressed = flags.contains(.maskSecondaryFn)

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
