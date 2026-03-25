import Cocoa
import AVFoundation
import ApplicationServices

public protocol PermissionManagerDelegate: AnyObject {
    func permissionStatusChanged(accessibility: Bool, microphone: Bool)
}

public class PermissionManager {
    public weak var delegate: PermissionManagerDelegate?

    private var pollingTimer: Timer?

    public private(set) var isAccessibilityGranted: Bool = false
    public private(set) var isMicrophoneGranted: Bool = false

    public var allPermissionsGranted: Bool {
        isAccessibilityGranted && isMicrophoneGranted
    }

    public init() {}

    deinit { stopMonitoring() }

    public func checkPermissions() {
        checkAccessibility()
        checkMicrophone()
    }

    public func requestPermissions() {
        // Accessibility: prompt the user via system dialog
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        isAccessibilityGranted = AXIsProcessTrustedWithOptions(options)

        // Microphone: request via AVFoundation
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.isMicrophoneGranted = granted
                self?.notifyDelegate()
            }
        }
    }

    public func startMonitoring() {
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkPermissions()
        }
    }

    public func stopMonitoring() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    public func checkGlobeKeySetting() -> Bool {
        // Read AppleFnUsageType from com.apple.HIToolbox defaults
        // 0 = Do Nothing, 1 = Change Input Source, 2 = Show Emoji & Symbols, 3 = Start Dictation
        let fnUsageType = UserDefaults.standard.persistentDomain(forName: "com.apple.HIToolbox")?["AppleFnUsageType"] as? Int
        // nil or 0 means "Do Nothing" — that's what we want
        return fnUsageType == nil || fnUsageType == 0
    }

    private func checkAccessibility() {
        let wasGranted = isAccessibilityGranted
        isAccessibilityGranted = AXIsProcessTrusted()
        if wasGranted != isAccessibilityGranted {
            notifyDelegate()
        }
    }

    private func checkMicrophone() {
        let wasGranted = isMicrophoneGranted
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            isMicrophoneGranted = true
        default:
            isMicrophoneGranted = false
        }
        if wasGranted != isMicrophoneGranted {
            notifyDelegate()
        }
    }

    private func notifyDelegate() {
        delegate?.permissionStatusChanged(
            accessibility: isAccessibilityGranted,
            microphone: isMicrophoneGranted
        )
    }
}
