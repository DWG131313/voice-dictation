import Cocoa
import Observation
import AVFoundation
import ApplicationServices

public protocol PermissionManagerDelegate: AnyObject {
    func permissionStatusChanged(accessibility: Bool, microphone: Bool)
}

/// Whether Accessibility and the microphone are granted, checked every 5
/// seconds while monitoring. It asks the system and never shows an alert of
/// its own: the onboarding window (Task 14) says what is missing.
@Observable
public final class PermissionManager {
    @ObservationIgnored public weak var delegate: PermissionManagerDelegate?

    @ObservationIgnored private var pollingTimer: Timer?

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

    /// True until the user has answered the system's microphone question.
    public var isMicrophoneUndetermined: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    /// Shows the system's microphone question; a no-op once answered.
    public func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = self.isMicrophoneGranted != granted
                self.isMicrophoneGranted = granted
                if changed { self.notifyDelegate() }
            }
        }
    }

    /// Shows the system's Accessibility question, which also lists this app
    /// in System Settings so it can be switched on.
    public func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
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

    /// The Globe key's setting in System Settings > Keyboard, as macOS saves
    /// it in `com.apple.HIToolbox`: 0 = Do Nothing, 1 = Change Input Source,
    /// 2 = Show Emoji & Symbols, 3 = Start Dictation; nil when never set,
    /// which behaves as Do Nothing.
    public static func globeKeyUsageType() -> Int? {
        UserDefaults.standard.persistentDomain(forName: "com.apple.HIToolbox")?["AppleFnUsageType"] as? Int
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
