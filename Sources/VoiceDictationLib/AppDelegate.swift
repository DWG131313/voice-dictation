import Cocoa
import Observation

/// Builds the app's parts at launch and connects them. Dictation itself, from
/// key press to paste, is `DictationPipeline`'s.
@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var service = TranscriptionService(
        engines: Self.engines(), selected: PreferencesManager.shared.selectedModelID
    )
    private lazy var pipeline = DictationPipeline(
        recorder: AudioRecorder(), service: service, paster: PasteEngine(),
        cleaner: nil, replacements: { [] }, vocabulary: { [] }
    )
    private lazy var statusManager = StatusManager()
    private lazy var transcriptionHistory = TranscriptionHistory()
    private let permissionManager = PermissionManager()
    private let hotkeyManager = HotkeyManager()
    private let comparisonRecordings = ComparisonRecordings()
    private var preferencesWindowController: PreferencesWindowController?
    /// Every model, as last listed in the Model submenu.
    private var models: [ModelDescriptor] = []
    /// True while the hotkey tap is armed. Tracked explicitly so that losing
    /// and re-gaining Accessibility restarts it cleanly.
    private var isListening = false

    private var isFirstLaunch: Bool {
        !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
    }

    /// `main.swift` creates the delegate outside the main actor. Everything
    /// with side effects is lazy, so it is built in `applicationDidFinishLaunching`.
    public nonisolated override init() {
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

        statusManager.delegate = self
        permissionManager.delegate = self
        hotkeyManager.delegate = self
        pipeline.onOutcome = { [weak self] outcome in self?.finished(outcome) }
        // No outcome, but the engine did transcribe the clip (Ruling T9-2).
        pipeline.onNothingHeard = { [weak self] clip, endedAt in
            self?.comparisonRecordings.keep(clip, rawText: "", date: endedAt)
        }
        showStateInMenuBar()
        statusManager.updateHistory(transcriptionHistory.entries)

        // Reconcile "open at login" with the user's preference. This is a
        // deliberate no-op for the dev build (.build) — registering a login
        // item from there accumulates a new stale entry on every rebuild,
        // which is what caused multiple instances to launch at startup.
        LoginItemManager.shared.syncWithStoredPreference()

        // Check permissions
        permissionManager.checkPermissions()
        Log.info("[INIT] Accessibility=\(permissionManager.isAccessibilityGranted) Microphone=\(permissionManager.isMicrophoneGranted)")
        showMissingPermission()

        if !permissionManager.allPermissionsGranted {
            Log.info("[INIT] Requesting permissions...")
            permissionManager.requestPermissions()
        }

        // Check Globe key setting
        if !permissionManager.checkGlobeKeySetting() {
            Log.info("[INIT] Globe key not set to Do Nothing")
            showGlobeKeyWarning()
        }

        // Start permission monitoring
        permissionManager.startMonitoring()

        // A dictation needs no model ready to start (Review Focus 1): it
        // waits for the model, or fails and is kept with its audio.
        startListening()

        Task {
            await refreshModels()
            // A failure is kept, and the next dictation tries again.
            await service.prepareSelected()
            await refreshModels()
        }

        Log.info("[INIT] Done. listening=\(isListening)")
    }

    /// The three engines dictation can use. WhisperKit keeps its models
    /// under Application Support; whisper-cli stays until Danny picks a
    /// default (Task 27).
    private static func engines() -> [TranscriptionEngine] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return [
            AppleSpeechEngine(),
            WhisperKitEngine(root: support.appendingPathComponent("VoiceDictation/whisperkit", isDirectory: true)),
            WhisperCLIEngine(),
        ]
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

    // MARK: - Wiring

    /// Shows the pipeline's state in the menu bar, now and after every change.
    private func showStateInMenuBar() {
        let pipeline = self.pipeline
        let statusManager = self.statusManager
        Task {
            for await state in Observations({ pipeline.state }) {
                statusManager.updateStatus(state)
            }
        }
    }

    /// After each dictation: keep its recording for the engine comparison
    /// when that is on, and add its text to the history.
    private func finished(_ outcome: DictationOutcome) {
        comparisonRecordings.keep(outcome)
        guard outcome.status != .failed, PreferencesManager.shared.historyEnabled else { return }
        transcriptionHistory.add(text: outcome.text)
        statusManager.updateHistory(transcriptionHistory.entries)
    }

    /// Lists the models again in the Model submenu.
    private func refreshModels() async {
        let models = await service.allModels()
        let selected = await service.selected
        self.models = models
        statusManager.updateModels(models, selected: selected)
    }

    /// Makes `model` the one dictation uses, downloading it first if it is
    /// not on the Mac, and remembers the choice. The pipeline shows the
    /// progress, and a failure, which leaves the selection as it was.
    private func choose(_ model: ModelDescriptor) {
        Task {
            do {
                try await pipeline.selectModel(model.id, named: model.displayName,
                                               downloadingFirst: model.state == .notDownloaded)
                PreferencesManager.shared.selectedModelID = model.id
            } catch {
                // Already shown and logged by the pipeline.
            }
            await refreshModels()
        }
    }

    /// The first permission dictation lacks, shown when nothing else is.
    private func showMissingPermission() {
        pipeline.missingPermission = !permissionManager.isAccessibilityGranted ? "Accessibility"
            : !permissionManager.isMicrophoneGranted ? "Microphone" : nil
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
        guard !isListening else { return }
        guard permissionManager.isAccessibilityGranted else {
            Log.info("[START] Waiting for Accessibility")
            return
        }
        hotkeyManager.start()
        isListening = true
        Log.info("[START] Listening for Globe key")
        showReadyAlert()
    }

    private func stopListening() {
        guard isListening else { return }
        Log.info("[STOP] Stopping listening")
        hotkeyManager.stop()
        // No key-up can arrive now, so end a recording under way here.
        pipeline.hotkeyUp()
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

// The managers below call their delegates on the main thread, which is what
// lets this main-actor class be their delegate.

// MARK: - PermissionManagerDelegate
extension AppDelegate: @preconcurrency PermissionManagerDelegate {
    public func permissionStatusChanged(accessibility: Bool, microphone: Bool) {
        Log.info("[PERM] permissionStatusChanged accessibility=\(accessibility) microphone=\(microphone)")
        showMissingPermission()
        if accessibility {
            startListening()
        } else {
            stopListening()
        }
    }
}

// MARK: - HotkeyDelegate
extension AppDelegate: @preconcurrency HotkeyDelegate {
    public func hotkeyDidStartPress() {
        pipeline.hotkeyDown()
    }

    public func hotkeyDidEndPress() {
        pipeline.hotkeyUp()
    }

    public func hotkeyCancelled() {
        pipeline.cancelHold()
    }
}

// MARK: - StatusManagerDelegate
extension AppDelegate: @preconcurrency StatusManagerDelegate {
    public func statusManagerDidRequestPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(modelManager: ModelManager())
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

    public func statusManagerDidChooseModel(_ model: ModelDescriptor) {
        choose(model)
    }

    public func statusManagerWillOpenMenu() {
        Task { await refreshModels() }
    }
}

// MARK: - PreferencesWindowDelegate
extension AppDelegate: @preconcurrency PreferencesWindowDelegate {
    /// The Preferences window still lists the whisper-cli models; choosing
    /// one there goes the same way as choosing it in the Model submenu.
    public func preferencesDidChangeModel(to modelId: String) {
        let id = ModelID(engine: .whisperCLI, name: modelId)
        guard let model = models.first(where: { $0.id == id }) else {
            Log.info("[MODEL] \(id.storageKey) is not among the listed models")
            return
        }
        choose(model)
    }
}
