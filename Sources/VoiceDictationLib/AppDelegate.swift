import Cocoa
import ServiceManagement

public class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusManager: StatusManager!
    private var permissionManager: PermissionManager!
    private var hotkeyManager: HotkeyManager!
    private var audioRecorder: AudioRecorder!
    private var transcriber: Transcriber!
    private var pasteEngine: PasteEngine!
    private var modelManager: ModelManager!
    private var isFirstLaunch: Bool {
        !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
    }

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusManager = StatusManager()
        permissionManager = PermissionManager()
        permissionManager.delegate = self

        audioRecorder = AudioRecorder()
        audioRecorder.delegate = self

        pasteEngine = PasteEngine()

        modelManager = ModelManager()
        modelManager.delegate = self

        hotkeyManager = HotkeyManager()
        hotkeyManager.delegate = self

        // Register as login item (macOS 13+)
        try? SMAppService.mainApp.register()

        // Check permissions
        permissionManager.checkPermissions()

        if !permissionManager.allPermissionsGranted {
            permissionManager.requestPermissions()
        }

        // Check Globe key setting
        if !permissionManager.checkGlobeKeySetting() {
            showGlobeKeyWarning()
        }

        // Check for whisper-cpp binary at startup
        if Transcriber.findBinaryPath() == nil {
            statusManager.updateStatus(.error(message: "whisper-cli not found. Run: brew install whisper-cpp"))
        }

        // Start permission monitoring
        permissionManager.startMonitoring()

        // Ensure model is downloaded
        modelManager.downloadModelIfNeeded()
    }

    private func showGlobeKeyWarning() {
        let alert = NSAlert()
        alert.messageText = "Globe Key Configuration Needed"
        alert.informativeText = "VoiceDictation uses the Globe key for push-to-talk. Please go to System Settings > Keyboard and set \"Press Globe key to\" to \"Do Nothing\"."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func startListening() {
        guard permissionManager.isAccessibilityGranted else {
            statusManager.updateStatus(.permissionNeeded("Accessibility"))
            return
        }

        guard Transcriber.findBinaryPath() != nil else {
            statusManager.updateStatus(.error(message: "whisper-cli not found. Run: brew install whisper-cpp"))
            return
        }

        transcriber = Transcriber(modelPath: modelManager.modelFileURL.path)
        transcriber.delegate = self

        hotkeyManager.start()
        statusManager.updateStatus(.idle)
    }

    private func showReadyAlert() {
        // Only show on first launch
        guard isFirstLaunch else { return }
        UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")

        let alert = NSAlert()
        alert.messageText = "VoiceDictation is Ready"
        alert.informativeText = "Hold the Globe key to dictate. Release to transcribe and paste."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - PermissionManagerDelegate
extension AppDelegate: PermissionManagerDelegate {
    public func permissionStatusChanged(accessibility: Bool, microphone: Bool) {
        if !accessibility {
            hotkeyManager.stop()
            statusManager.updateStatus(.permissionNeeded("Accessibility"))
        } else if !microphone {
            statusManager.updateStatus(.permissionNeeded("Microphone"))
        } else {
            if transcriber == nil && modelManager.isModelPresent {
                startListening()
            }
        }
    }
}

// MARK: - HotkeyDelegate
extension AppDelegate: HotkeyDelegate {
    public func hotkeyDidStartPress() {
        guard permissionManager.isMicrophoneGranted else {
            statusManager.updateStatus(.permissionNeeded("Microphone"))
            return
        }
        statusManager.updateStatus(.recording)
        audioRecorder.startRecording()
    }

    public func hotkeyDidEndPress() {
        audioRecorder.stopRecording()
    }

    public func hotkeyCancelled() {
        audioRecorder.cancelRecording()
        statusManager.updateStatus(.idle)
    }
}

// MARK: - AudioRecorderDelegate
extension AppDelegate: AudioRecorderDelegate {
    public func recordingDidStart() {}

    public func recordingDidFinish(fileURL: URL, duration: TimeInterval) {
        statusManager.updateStatus(.transcribing(queued: 0))
        transcriber.transcribe(fileURL: fileURL, recordingDuration: duration)
    }

    public func recordingDidFail(error: String) {
        statusManager.updateStatus(.error(message: error))
    }

    public func recordingDiscarded() {
        statusManager.updateStatus(.idle)
    }
}

// MARK: - TranscriberDelegate
extension AppDelegate: TranscriberDelegate {
    public func transcriptionCompleted(text: String) {
        pasteEngine.paste(text: text)
        statusManager.updateStatus(.idle)
    }

    public func transcriptionFailed(error: String) {
        statusManager.updateStatus(.error(message: error))
    }

    public func transcriptionQueueUpdated(count: Int) {
        if count > 0 {
            statusManager.updateStatus(.transcribing(queued: count))
        }
    }
}

// MARK: - ModelManagerDelegate
extension AppDelegate: ModelManagerDelegate {
    public func modelDownloadProgress(_ progress: Double) {
        statusManager.updateStatus(.downloading(progress: progress))
    }

    public func modelDownloadCompleted() {
        if permissionManager.allPermissionsGranted {
            startListening()
            showReadyAlert()
        }
    }

    public func modelDownloadFailed(error: String) {
        statusManager.updateStatus(.error(message: error))
    }
}
