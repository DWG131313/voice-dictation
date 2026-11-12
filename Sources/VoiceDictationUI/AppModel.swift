import AppKit
import Observation
import VoiceDictationLib

/// The app: builds its parts and connects them, starts them once launching
/// has finished, and is the one object the views read. Dictation itself,
/// from key press to paste, is `DictationPipeline`'s. Use from the main thread.
@MainActor @Observable
public final class AppModel {
    /// The main window's scene, for `openWindow(id:)`.
    public static let mainWindowID = "main"

    public let pipeline: DictationPipeline
    public let service: TranscriptionService
    public let store: TranscriptStore
    public let permissions: PermissionManager
    public let hotkeys: HotkeyManager
    /// Every model, as last listed by `refreshModels()`.
    public private(set) var models: [ModelDescriptor] = []
    /// The model dictation uses, as last listed; nil until then.
    public private(set) var selectedModel: ModelID?

    @ObservationIgnored private let preferences: PreferencesManager
    @ObservationIgnored private let comparisonRecordings: ComparisonRecordings
    /// Where the store is, and where the old app kept `history.json`.
    @ObservationIgnored private let dataDirectory: URL
    /// True while the hotkey tap is armed. Tracked explicitly so that losing
    /// and re-gaining Accessibility restarts it cleanly.
    @ObservationIgnored private var isListening = false
    /// Lists the models again whenever a menu opens; kept as long as the app runs.
    @ObservationIgnored private var menuObserver: NSObjectProtocol?

    private var isFirstLaunch: Bool {
        !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
    }

    /// The app's parts: the three engines with the model saved for dictation,
    /// the microphone, the paste, and the store with its kept recordings in
    /// `~/Library/Application Support/VoiceDictation/`.
    public convenience init() {
        let directory = Self.dataDirectory
        let preferences = PreferencesManager.shared
        self.init(
            service: TranscriptionService(engines: Self.engines(), selected: preferences.selectedModelID),
            recorder: AudioRecorder(),
            paster: PasteEngine(),
            store: TranscriptStore(
                directory: directory,
                audio: AudioArchive(directory: directory.appendingPathComponent("audio", isDirectory: true)),
                keptRecordings: { preferences.keptRecordings }
            ),
            preferences: preferences,
            comparison: ComparisonRecordings(),
            dataDirectory: directory
        )
    }

    /// Connects the parts, with no side effects: `start()` asks for
    /// permissions and arms the hotkey. Tests pass fakes, an in-memory store
    /// and preferences kept in memory.
    init(service: TranscriptionService, recorder: Recording, paster: Pasting, store: TranscriptStore,
         preferences: PreferencesManager, comparison: ComparisonRecordings, dataDirectory: URL) {
        self.service = service
        // Tasks 21 and 22 add the cleaner and the replacements.
        self.pipeline = DictationPipeline(recorder: recorder, service: service, paster: paster,
                                          cleaner: nil, replacements: { [] }, vocabulary: { [] })
        self.store = store
        self.permissions = PermissionManager()
        self.hotkeys = HotkeyManager()
        self.preferences = preferences
        self.comparisonRecordings = comparison
        self.dataDirectory = dataDirectory

        permissions.delegate = self
        hotkeys.delegate = self
        pipeline.onOutcome = { [weak self] outcome in self?.finished(outcome) }
        // No outcome, but the engine did transcribe the clip (Ruling T9-2).
        pipeline.onNothingHeard = { [weak self] clip, endedAt in
            self?.comparisonRecordings.keep(clip, rawText: "", date: endedAt)
        }
        listModelsWhenAMenuOpens()
    }

    /// Starts the app; called once, when launching has finished. Imports the
    /// old history, asks for missing permissions, arms the Globe key and
    /// loads the model dictation uses.
    public func start() {
        Log.info("[INIT] applicationDidFinishLaunching (log: \(Log.fileURL.path))")

        cleanupStaleRecordings()
        importHistory()

        // Reconcile "open at login" with the user's preference. This is a
        // deliberate no-op for dev builds (anything under .build): registering
        // a login item from there accumulates a new stale entry on every
        // rebuild, which is what caused multiple instances to launch at startup.
        LoginItemManager.shared.syncWithStoredPreference()

        // Check permissions
        permissions.checkPermissions()
        Log.info("[INIT] Accessibility=\(permissions.isAccessibilityGranted) Microphone=\(permissions.isMicrophoneGranted)")
        showMissingPermission()

        if !permissions.allPermissionsGranted {
            Log.info("[INIT] Requesting permissions...")
            permissions.requestPermissions()
        }

        // Check Globe key setting
        if !permissions.checkGlobeKeySetting() {
            Log.info("[INIT] Globe key not set to Do Nothing")
            showGlobeKeyWarning()
        }

        // Start permission monitoring
        permissions.startMonitoring()

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

    // MARK: - Models

    /// Lists every model again, and the one dictation uses.
    public func refreshModels() async {
        let models = await service.allModels()
        let selected = await service.selected
        self.models = models
        self.selectedModel = selected
    }

    /// Makes `model` the one dictation uses, downloading it first if it is
    /// not on the Mac, and remembers the choice. The pipeline shows the
    /// progress, and a failure, which leaves the choice as it was.
    func choose(_ model: ModelDescriptor) async {
        do {
            try await pipeline.selectModel(model.id, named: model.displayName,
                                           downloadingFirst: model.state == .notDownloaded)
            preferences.selectedModelID = model.id
        } catch {
            // Already shown and logged by the pipeline.
        }
        await refreshModels()
    }

    /// Lists the models again whenever a menu opens, the menu bar menu among
    /// them, so the Model submenu's states and checkmark are current (Ruling
    /// T9-3). AppKit posts this for every menu; listing them is cheap.
    private func listModelsWhenAMenuOpens() {
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.refreshModels() }
        }
    }

    // MARK: - Wiring

    /// `~/Library/Application Support/VoiceDictation/`, where the app keeps
    /// its transcripts and the old app kept `history.json`.
    private static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceDictation", isDirectory: true)
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

    /// After each dictation: keep its recording for the engine comparison
    /// when that is on, and keep its transcript, a failed one too (Review
    /// Focus 4).
    private func finished(_ outcome: DictationOutcome) {
        comparisonRecordings.keep(outcome)
        store.add(outcome)
    }

    /// Brings the old app's `history.json` into the store, once. The file
    /// itself is left as it was.
    private func importHistory() {
        let file = dataDirectory.appendingPathComponent("history.json")
        _ = HistoryImporter.importIfNeeded(from: file, into: store, defaults: .standard)
    }

    /// The first permission dictation lacks, shown when nothing else is.
    private func showMissingPermission() {
        pipeline.missingPermission = !permissions.isAccessibilityGranted ? "Accessibility"
            : !permissions.isMicrophoneGranted ? "Microphone" : nil
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
        guard permissions.isAccessibilityGranted else {
            Log.info("[START] Waiting for Accessibility")
            return
        }
        hotkeys.start()
        isListening = true
        Log.info("[START] Listening for Globe key")
        showReadyAlert()
    }

    private func stopListening() {
        guard isListening else { return }
        Log.info("[STOP] Stopping listening")
        hotkeys.stop()
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
extension AppModel: @preconcurrency PermissionManagerDelegate {
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
extension AppModel: @preconcurrency HotkeyDelegate {
    public func hotkeyDidStartPress() {
        pipeline.hotkeyDown()
    }

    public func hotkeyDidEndPress() {
        pipeline.hotkeyUp()
    }

    /// A key pressed with the hotkey held cancels this hold's dictation and
    /// nothing else; `cancel()` is Task 23's cancel-everything.
    public func hotkeyCancelled() {
        pipeline.cancelHold()
    }
}

/// The app's AppKit side, installed by `VoiceDictationApp` through
/// `@NSApplicationDelegateAdaptor`. It builds the `AppModel` when first asked
/// for it and starts it once launching has finished. It keeps the app in the
/// menu bar only, with a Dock icon and a menu of its own just while the main
/// window is open, and keeps it running when that window closes.
@MainActor
public final class AppLifecycle: NSObject, NSApplicationDelegate {
    /// Built on first use rather than with the delegate, so a second copy of
    /// the app, which `VoiceDictationApp.init` turns away, never builds one.
    public private(set) lazy var model = AppModel()

    /// SwiftUI makes the delegate, maybe before `VoiceDictationApp.init` runs.
    public nonisolated override init() {
        super.init()
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu bar only. A regular-policy app that activates would take
        // keyboard focus away from the app we're about to paste into.
        NSApp.setActivationPolicy(.accessory)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    /// Closing the window leaves the app running in the menu bar.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The main window has opened: a Dock icon and the app's own menu bar,
    /// as for any app with a window.
    public func mainWindowDidOpen() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// The main window has closed: back to the menu bar only.
    public func mainWindowDidClose() {
        NSApp.setActivationPolicy(.accessory)
        // Going back to accessory can leave this app active with no window,
        // and a dictation made then would paste nowhere. Hiding hands focus
        // back to the app that was in front, unless Settings is still open.
        let otherWindowOpen = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        if !otherWindowOpen {
            NSApp.hide(nil)
        }
    }
}
