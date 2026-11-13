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
    /// The Welcome window's scene.
    public static let welcomeWindowID = "onboarding"

    public let pipeline: DictationPipeline
    public let service: TranscriptionService
    public let store: TranscriptStore
    /// The main window's transcripts: what is listed and selected.
    public let library: LibraryModel
    public let permissions: PermissionManager
    public let hotkeys: HotkeyManager
    /// Every model, as last listed by `refreshModels()`.
    public private(set) var models: [ModelDescriptor] = []
    /// The model dictation uses, as last listed; nil until then.
    public private(set) var selectedModel: ModelID?
    /// The Welcome window's steps.
    @ObservationIgnored public private(set) lazy var onboarding = OnboardingModel(
        system: onboardingSystem,
        service: service,
        models: { [unowned self] in models },
        selected: { [unowned self] in selectedModel },
        refreshModels: { [unowned self] in await refreshModels() },
        preferences: preferences
    )
    /// Counts the times the app has asked for the Welcome window to open at
    /// launch; the menu bar icon, which has the `openWindow` action, opens it
    /// and takes the request (`takeWelcomeRequest`).
    public private(set) var welcomeRequests = 0
    @ObservationIgnored private var welcomeRequestsServed = 0
    @ObservationIgnored private let onboardingSystem: OnboardingSystem

    @ObservationIgnored private let preferences: PreferencesManager
    @ObservationIgnored private let comparisonRecordings: ComparisonRecordings
    /// Where the store is, and where the old app kept `history.json`.
    @ObservationIgnored private let dataDirectory: URL
    /// True while the hotkey tap is armed. Tracked explicitly so that losing
    /// and re-gaining Accessibility restarts it cleanly.
    @ObservationIgnored private var isListening = false
    /// Lists the models again whenever a menu opens; kept as long as the app runs.
    @ObservationIgnored private var menuObserver: NSObjectProtocol?
    /// The floating indicator; none in tests that do not ask for one.
    @ObservationIgnored private let indicator: IndicatorPresenting?
    /// The indicator's volume line, fed from `pipeline.level` while recording.
    @ObservationIgnored private var indicatorLine = LevelLine()
    /// When the recording `indicatorLine` belongs to started.
    @ObservationIgnored private var indicatorRecordingStart: Date?

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
            dataDirectory: directory,
            indicator: IndicatorPanel()
        )
    }

    /// Connects the parts, with no side effects: `start()` asks for
    /// permissions and arms the hotkey. Tests pass fakes, an in-memory store
    /// and preferences kept in memory.
    init(service: TranscriptionService, recorder: Recording, paster: Pasting, store: TranscriptStore,
         preferences: PreferencesManager, comparison: ComparisonRecordings, dataDirectory: URL,
         onboardingSystem: OnboardingSystem? = nil, indicator: IndicatorPresenting? = nil,
         pasteAgain: PasteAgainSystem? = nil) {
        // Once, at launch, before any view asks for Jost, Work Sans or DM Mono.
        Fonts.registerAll()
        self.service = service
        // Task 22 adds the vocabulary, for dictation and re-transcription alike.
        let vocabulary: () -> [String] = { [] }
        // Tasks 21 and 22 add the cleaner and the replacements.
        self.pipeline = DictationPipeline(recorder: recorder, service: service, paster: paster,
                                          cleaner: nil, replacements: { [] }, vocabulary: vocabulary)
        self.store = store
        self.library = LibraryModel(store: store, service: service, paster: paster, vocabulary: vocabulary,
                                    system: pasteAgain ?? .live())
        self.permissions = PermissionManager()
        // Tests pass a fake: the live one reads the real HIToolbox settings.
        self.onboardingSystem = onboardingSystem ?? .live(permissions: permissions)
        self.hotkeys = HotkeyManager()
        self.preferences = preferences
        self.comparisonRecordings = comparison
        self.dataDirectory = dataDirectory
        self.indicator = indicator

        permissions.delegate = self
        hotkeys.delegate = self
        pipeline.onOutcome = { [weak self] outcome in self?.finished(outcome) }
        // No outcome, but the engine did transcribe the clip (Ruling T9-2).
        pipeline.onNothingHeard = { [weak self] clip, endedAt in
            self?.comparisonRecordings.keep(clip, rawText: "", date: endedAt)
        }
        listModelsWhenAMenuOpens()
        observeStateForIndicator()
        observeLevelForIndicator()
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

        // Check permissions. Nothing is asked for here: the Welcome window
        // has a button for each, so a prompt never lands on a user who has
        // not yet been told why.
        permissions.checkPermissions()
        Log.info("[INIT] Accessibility=\(permissions.isAccessibilityGranted) Microphone=\(permissions.isMicrophoneGranted)")
        showMissingPermission()

        // Start permission monitoring
        permissions.startMonitoring()

        // A dictation needs no model ready to start (Review Focus 1): it
        // waits for the model, or fails and is kept with its audio.
        startListening()

        // Read now, before anything can be marked as launched.
        let firstLaunch = !preferences.hasLaunchedBefore
        preferences.hasLaunchedBefore = true

        Task {
            await refreshModels()
            // Only now is the model list known (it is empty until the first
            // refresh), so only now can the steps be judged.
            await decideWelcomeAtLaunch(firstLaunch: firstLaunch)
            // A failure is kept, and the next dictation tries again.
            await service.prepareSelected()
            await refreshModels()
        }

        Log.info("[INIT] Done. listening=\(isListening)")
    }

    // MARK: - Welcome window

    /// Asks for the Welcome window on the first run, or when a step is left.
    /// Call once the models are listed.
    func decideWelcomeAtLaunch(firstLaunch: Bool) async {
        await refreshModels()
        onboarding.refresh()
        if onboarding.shouldShowAtLaunch(firstLaunch: firstLaunch) {
            welcomeRequests += 1
        }
    }

    /// True once per request: the view that opens the window takes it, so a
    /// view appearing again later opens nothing and takes no focus.
    public func takeWelcomeRequest() -> Bool {
        guard welcomeRequestsServed < welcomeRequests else { return false }
        welcomeRequestsServed = welcomeRequests
        return true
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

    // MARK: - The indicator

    // `withObservationTracking` reports a change once, as the value is about
    // to be set. So each handler reads the new value a turn later on the main
    // actor, and watches again.

    private func observeStateForIndicator() {
        withObservationTracking {
            _ = pipeline.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeStateForIndicator()
                self?.updateIndicator()
            }
        }
    }

    private func observeLevelForIndicator() {
        withObservationTracking {
            _ = pipeline.level
        } onChange: { [weak self] in
            // When the level arrived, on the line's monotonic clock: the line
            // places each peak by its arrival, not by when it is drawn.
            let arrived = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in
                self?.observeLevelForIndicator()
                self?.updateIndicator(levelArrivedAt: arrived)
            }
        }
    }

    /// Shows the floating indicator while a dictation is recorded, transcribed
    /// or cleaned up, and hides it otherwise. A new recording starts a new
    /// line; a level that arrived at `time` while recording goes into it.
    /// Showing the indicator never activates the app or changes its
    /// activation policy (`IndicatorPanel`), so it stays out of `WindowPolicy`.
    private func updateIndicator(levelArrivedAt time: TimeInterval? = nil) {
        let state = pipeline.state
        guard IndicatorView.words(for: state) != nil else {
            indicator?.hide()
            return
        }
        if case .recording(let since) = state {
            if since != indicatorRecordingStart {
                indicatorLine.reset()
                indicatorRecordingStart = since
            }
            if let time {
                indicatorLine.add(peak: pipeline.level, at: time)
            }
        }
        indicator?.show(state, line: indicatorLine)
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
    /// Focus 4), which the window's list then shows, open or not.
    private func finished(_ outcome: DictationOutcome) {
        comparisonRecordings.keep(outcome)
        let transcript = store.add(outcome)
        onboarding.recordOutcome(outcome)
        if let transcript { library.noteNewTranscript(transcript) }
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

    private func startListening() {
        guard !isListening else { return }
        guard permissions.isAccessibilityGranted else {
            Log.info("[START] Waiting for Accessibility")
            return
        }
        hotkeys.start()
        isListening = true
        Log.info("[START] Listening for Globe key")
    }

    private func stopListening() {
        guard isListening else { return }
        Log.info("[STOP] Stopping listening")
        hotkeys.stop()
        // No key-up can arrive now, so end a recording under way here.
        pipeline.hotkeyUp()
        isListening = false
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

    /// Tests pass a model built from fakes.
    init(model: AppModel) {
        super.init()
        self.model = model
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu bar only. A regular-policy app that activates would take
        // keyboard focus away from the app we're about to paste into.
        NSApp.setActivationPolicy(.accessory)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    /// Quitting saves the edit being typed in the main window at once: its
    /// autosave waits about half a second after the last keystroke, and the
    /// app would be gone by then.
    public func applicationWillTerminate(_ notification: Notification) {
        model.library.commitEdit()
    }

    /// Closing the window leaves the app running in the menu bar.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A window (the main one or Welcome) has opened: a Dock icon and the
    /// app's own menu bar, as for any app with a window.
    public func windowDidOpen() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// A window has closed. Inside `onDisappear` the closing window may still
    /// report itself visible, so the windows are counted a turn later. With
    /// none left the app returns to the menu bar only and hides, handing
    /// focus back to the app that was in front: a dictation made while this
    /// app was active with no window would paste nowhere.
    public func windowDidClose() {
        DispatchQueue.main.async {
            let windows = NSApp.windows.map { WindowSnapshot(isVisible: $0.isVisible, isMiniaturized: $0.isMiniaturized, canBecomeMain: $0.canBecomeMain) }
            guard WindowPolicy.afterClose(windows: windows) == .leaveAndHide else { return }
            NSApp.setActivationPolicy(.accessory)
            NSApp.hide(nil)
        }
    }
}
