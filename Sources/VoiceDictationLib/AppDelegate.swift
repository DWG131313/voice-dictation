import Cocoa

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
    /// True while the hotkey tap is armed and a transcriber is ready.
    /// Tracked explicitly so that losing and re-gaining a permission can
    /// restart listening cleanly.
    private var isListening = false

    /// Timing for the dictation being recorded, then a FIFO of dictations
    /// waiting on the transcriber (it finishes them in order).
    private var currentTimer = StageTimer()
    private struct PendingDictation {
        var timer: StageTimer
        /// Unix time in milliseconds naming the kept `.wav`/`.txt` pair; nil when not keeping.
        var comparisonStem: String?
        let fileURL: URL
    }
    private var pending: [PendingDictation] = []
    private var isFirstLaunch: Bool {
        !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
    }

    public override init() {
        super.init()
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu bar only, whether launched from a .app bundle (where
        // LSUIElement handles it) or straight from the build directory. A
        // regular-policy app that activates would take keyboard focus away
        // from the app we're about to paste into.
        NSApp.setActivationPolicy(.accessory)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("[INIT] applicationDidFinishLaunching (log: \(Log.fileURL.path))")

        cleanupStaleRecordings()

        statusManager = StatusManager()
        statusManager.delegate = self

        permissionManager = PermissionManager()
        permissionManager.delegate = self

        audioRecorder = AudioRecorder()
        audioRecorder.delegate = self
        audioRecorder.onFirstAudio = { [weak self] time in
            self?.currentTimer.mark(.firstAudio, at: time)
        }

        pasteEngine = PasteEngine()

        modelManager = ModelManager()
        modelManager.delegate = self

        transcriptionHistory = TranscriptionHistory()

        hotkeyManager = HotkeyManager()
        hotkeyManager.delegate = self

        // Reconcile "open at login" with the user's preference. This is a
        // deliberate no-op for the dev build (.build) — registering a login
        // item from there accumulates a new stale entry on every rebuild,
        // which is what caused multiple instances to launch at startup.
        LoginItemManager.shared.syncWithStoredPreference()

        // Check permissions
        permissionManager.checkPermissions()
        Log.info("[INIT] Accessibility=\(permissionManager.isAccessibilityGranted) Microphone=\(permissionManager.isMicrophoneGranted)")

        if !permissionManager.allPermissionsGranted {
            Log.info("[INIT] Requesting permissions...")
            permissionManager.requestPermissions()
        }

        // Check Globe key setting
        if !permissionManager.checkGlobeKeySetting() {
            Log.info("[INIT] Globe key not set to Do Nothing")
            showGlobeKeyWarning()
        }

        // Check for whisper-cli binary at startup
        let whisperPath = BundledBinary.findWhisperCLI()
        Log.info("[INIT] whisper-cli path: \(whisperPath ?? "NOT FOUND")")
        if whisperPath == nil {
            statusManager.updateStatus(.error(message: "whisper-cli not found. Run: brew install whisper-cpp"))
        }

        // Start permission monitoring
        permissionManager.startMonitoring()

        // Update history display
        statusManager.updateHistory(transcriptionHistory.entries)

        // Ensure model is downloaded
        Log.info("[INIT] Model present=\(modelManager.isModelPresent) path=\(modelManager.modelFileURL.path)")
        modelManager.downloadModelIfNeeded()

        Log.info("[INIT] Done. listening=\(isListening)")
    }

    /// Recordings left behind by a crash mid-transcription. They live in the
    /// temp directory, but there is no reason to let them pile up.
    private func cleanupStaleRecordings() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) else { return }
        var removed = 0
        for file in files where file.lastPathComponent.hasPrefix("voice-dictation-") && file.pathExtension == "wav" {
            try? FileManager.default.removeItem(at: file)
            removed += 1
        }
        if removed > 0 {
            Log.info("[INIT] Removed \(removed) stale recording(s)")
        }
    }

    // MARK: - Comparison recordings

    private static var comparisonDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceDictation/comparison", isDirectory: true)
    }

    /// Copies the WAV aside (the transcriber deletes it when done). Returns
    /// the shared file name stem, or nil when the preference is off or the
    /// copy failed.
    private func keepComparisonRecording(of wav: URL) -> String? {
        guard PreferencesManager.shared.keepComparisonRecordings else { return nil }
        let dir = Self.comparisonDirectory
        let stem = String(Int(Date().timeIntervalSince1970 * 1000))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: wav, to: dir.appendingPathComponent("\(stem).wav"))
            return stem
        } catch {
            Log.info("[COMPARE] Could not keep recording: \(error.localizedDescription)")
            return nil
        }
    }

    private func saveComparisonTranscript(_ text: String, stem: String) {
        let url = Self.comparisonDirectory.appendingPathComponent("\(stem).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.info("[COMPARE] Could not save transcript: \(error.localizedDescription)")
        }
    }

    private func showGlobeKeyWarning() {
        let alert = NSAlert()
        alert.messageText = "Globe Key Configuration Needed"
        alert.informativeText = "VoiceDictation uses the Globe key for push-to-talk. In System Settings > Keyboard, set \"Press 🌐 key to\" to \"Do Nothing\"."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Keyboard Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startListening() {
        Log.info("[START] startListening called")
        guard !isListening else {
            Log.info("[START] Already listening, skipping")
            return
        }
        guard permissionManager.isAccessibilityGranted else {
            Log.info("[START] BLOCKED — Accessibility not granted")
            statusManager.updateStatus(.permissionNeeded("Accessibility"))
            return
        }

        guard BundledBinary.findWhisperCLI() != nil else {
            Log.info("[START] BLOCKED — whisper-cli not found")
            statusManager.updateStatus(.error(message: "whisper-cli not found. Run: brew install whisper-cpp"))
            return
        }

        transcriber = Transcriber(modelPath: modelManager.modelFileURL.path)
        transcriber.delegate = self

        hotkeyManager.start()
        isListening = true
        Log.info("[START] Listening for Globe key")
        statusManager.updateStatus(.idle)
    }

    private func stopListening() {
        guard isListening else { return }
        Log.info("[STOP] Stopping listening")
        hotkeyManager.stop()
        audioRecorder.cancelRecording()
        isListening = false
    }

    private func showReadyAlert() {
        guard isFirstLaunch else { return }
        UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")

        let alert = NSAlert()
        alert.messageText = "VoiceDictation is Ready"
        alert.informativeText = "Hold the Globe key to dictate. Release to transcribe and paste."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - PermissionManagerDelegate
extension AppDelegate: PermissionManagerDelegate {
    public func permissionStatusChanged(accessibility: Bool, microphone: Bool) {
        Log.info("[PERM] permissionStatusChanged accessibility=\(accessibility) microphone=\(microphone)")
        if !accessibility {
            stopListening()
            statusManager.updateStatus(.permissionNeeded("Accessibility"))
        } else if !microphone {
            statusManager.updateStatus(.permissionNeeded("Microphone"))
        } else {
            Log.info("[PERM] All granted. listening=\(isListening) modelPresent=\(modelManager.isModelPresent)")
            if !isListening && modelManager.isModelPresent {
                startListening()
            }
        }
    }
}

// MARK: - HotkeyDelegate
extension AppDelegate: HotkeyDelegate {
    public func hotkeyDidStartPress() {
        guard permissionManager.isMicrophoneGranted else {
            Log.info("[KEY] BLOCKED — Microphone not granted")
            statusManager.updateStatus(.permissionNeeded("Microphone"))
            return
        }
        currentTimer = StageTimer()
        currentTimer.mark(.keyDown)
        statusManager.updateStatus(.recording)
        audioRecorder.startRecording()
    }

    public func hotkeyDidEndPress() {
        currentTimer.mark(.keyUp)
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
        pending.append(PendingDictation(
            timer: currentTimer,
            comparisonStem: keepComparisonRecording(of: fileURL),
            fileURL: fileURL))
        statusManager.updateStatus(.transcribing(queued: 0))
        transcriber.transcribe(fileURL: fileURL, recordingDuration: duration)
    }

    public func recordingDidFail(error: String) {
        Log.info("[AUDIO] Recording failed: \(error)")
        statusManager.updateStatus(.error(message: error))
    }

    public func recordingDiscarded() {
        statusManager.updateStatus(.idle)
    }
}

// MARK: - TranscriberDelegate
extension AppDelegate: TranscriberDelegate {
    public func transcriptionCompleted(text: String) {
        var dictation = pending.isEmpty ? PendingDictation(timer: StageTimer(), comparisonStem: nil, fileURL: URL(fileURLWithPath: "/")) : pending.removeFirst()
        dictation.timer.mark(.textReady)
        if let stem = dictation.comparisonStem {
            saveComparisonTranscript(text, stem: stem)
        }
        if !text.isEmpty {
            pasteEngine.paste(text: text)
            dictation.timer.mark(.pasted)
            Log.info("[TIMING] \(dictation.timer.summary)")

            if PreferencesManager.shared.historyEnabled {
                transcriptionHistory.add(text: text)
                statusManager.updateHistory(transcriptionHistory.entries)
            }
        }

        statusManager.updateStatus(.idle)
    }

    public func transcriptionFailed(error: String) {
        if !pending.isEmpty { pending.removeFirst() }
        statusManager.updateStatus(.error(message: error))
    }

    public func transcriptionDropped(fileURL: URL) {
        pending.removeAll { $0.fileURL == fileURL }
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
        Log.info("[MODEL] Ready. allPermissionsGranted=\(permissionManager.allPermissionsGranted)")
        statusManager.updateModelDisplay()
        if permissionManager.allPermissionsGranted {
            startListening()
            showReadyAlert()
        } else {
            Log.info("[MODEL] NOT starting — permissions not granted yet")
        }
    }

    public func modelDownloadFailed(error: String) {
        Log.info("[MODEL] Download failed: \(error)")
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
        Log.info("[MODEL] Switching to \(modelId)")
        stopListening()
        transcriber = nil
        modelManager.switchModel(to: modelId)
        // modelDownloadCompleted will restart listening when ready
    }
}
