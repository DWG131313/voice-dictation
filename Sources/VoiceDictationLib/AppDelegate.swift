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
    private var transcriptionHistory: TranscriptionHistory!
    private var preferencesWindowController: PreferencesWindowController?
    private var isFirstLaunch: Bool {
        !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
    }

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        log("[INIT] applicationDidFinishLaunching")

        statusManager = StatusManager()
        statusManager.delegate = self

        permissionManager = PermissionManager()
        permissionManager.delegate = self

        audioRecorder = AudioRecorder()
        audioRecorder.delegate = self

        pasteEngine = PasteEngine()

        modelManager = ModelManager()
        modelManager.delegate = self

        transcriptionHistory = TranscriptionHistory()

        hotkeyManager = HotkeyManager()
        hotkeyManager.delegate = self

        // Register as login item (macOS 13+) on first launch only
        if isFirstLaunch {
            try? SMAppService.mainApp.register()
        }

        // Check permissions
        permissionManager.checkPermissions()
        log("[INIT] Accessibility=\(permissionManager.isAccessibilityGranted) Microphone=\(permissionManager.isMicrophoneGranted)")

        if !permissionManager.allPermissionsGranted {
            log("[INIT] Requesting permissions...")
            permissionManager.requestPermissions()
        }

        // Check Globe key setting
        if !permissionManager.checkGlobeKeySetting() {
            log("[INIT] Globe key not set to Do Nothing")
            showGlobeKeyWarning()
        }

        // Check for whisper-cli binary at startup
        let whisperPath = BundledBinary.findWhisperCLI()
        log("[INIT] whisper-cli path: \(whisperPath ?? "NOT FOUND")")
        if whisperPath == nil {
            statusManager.updateStatus(.error(message: "whisper-cli not found. Run: brew install whisper-cpp"))
        }

        // Start permission monitoring
        permissionManager.startMonitoring()

        // Update history display
        statusManager.updateHistory(transcriptionHistory.entries)

        // Ensure model is downloaded
        log("[INIT] Model present=\(modelManager.isModelPresent) path=\(modelManager.modelFileURL.path)")
        modelManager.downloadModelIfNeeded()

        log("[INIT] Done. transcriber=\(transcriber != nil ? "set" : "nil")")
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)"
        print(line)
        // Also append to log file
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceDictation.log")
        if let data = (line + "\n").data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
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
        log("[START] startListening called")
        guard transcriber == nil else {
            log("[START] Already listening, skipping")
            return
        }
        guard permissionManager.isAccessibilityGranted else {
            log("[START] BLOCKED — Accessibility not granted")
            statusManager.updateStatus(.permissionNeeded("Accessibility"))
            return
        }

        guard BundledBinary.findWhisperCLI() != nil else {
            log("[START] BLOCKED — whisper-cli not found")
            statusManager.updateStatus(.error(message: "whisper-cli not found. Run: brew install whisper-cpp"))
            return
        }

        transcriber = Transcriber(modelPath: modelManager.modelFileURL.path)
        transcriber.delegate = self
        log("[START] Transcriber created. Calling hotkeyManager.start()")

        hotkeyManager.start()
        log("[START] hotkeyManager.start() returned")
        statusManager.updateStatus(.idle)
    }

    private func showReadyAlert() {
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
        log("[PERM] permissionStatusChanged accessibility=\(accessibility) microphone=\(microphone)")
        if !accessibility {
            hotkeyManager.stop()
            statusManager.updateStatus(.permissionNeeded("Accessibility"))
        } else if !microphone {
            statusManager.updateStatus(.permissionNeeded("Microphone"))
        } else {
            log("[PERM] All granted. transcriber=\(transcriber != nil ? "set" : "nil") modelPresent=\(modelManager.isModelPresent)")
            if transcriber == nil && modelManager.isModelPresent {
                startListening()
            }
        }
    }
}

// MARK: - HotkeyDelegate
extension AppDelegate: HotkeyDelegate {
    public func hotkeyDidStartPress() {
        log("[KEY] Globe key PRESSED. micGranted=\(permissionManager.isMicrophoneGranted)")
        guard permissionManager.isMicrophoneGranted else {
            log("[KEY] BLOCKED — Microphone not granted")
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

        if PreferencesManager.shared.historyEnabled {
            transcriptionHistory.add(text: text)
            statusManager.updateHistory(transcriptionHistory.entries)
        }

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
        log("[MODEL] Download completed. allPermissionsGranted=\(permissionManager.allPermissionsGranted)")
        statusManager.updateModelDisplay()
        if permissionManager.allPermissionsGranted {
            startListening()
            showReadyAlert()
        } else {
            log("[MODEL] NOT starting — permissions not granted yet")
        }
    }

    public func modelDownloadFailed(error: String) {
        statusManager.updateStatus(.error(message: error))
    }
}

// MARK: - StatusManagerDelegate
extension AppDelegate: StatusManagerDelegate {
    public func statusManagerDidRequestPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(modelManager: modelManager)
            preferencesWindowController?.preferencesDelegate = self
        }
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func statusManagerDidRequestClearHistory() {
        transcriptionHistory.clear()
        statusManager.updateHistory(transcriptionHistory.entries)
    }
}

// MARK: - PreferencesWindowDelegate
extension AppDelegate: PreferencesWindowDelegate {
    public func preferencesDidChangeModel(to modelId: String) {
        hotkeyManager.stop()
        transcriber = nil
        modelManager.switchModel(to: modelId)
        // modelDownloadCompleted will restart listening when ready
    }
}
