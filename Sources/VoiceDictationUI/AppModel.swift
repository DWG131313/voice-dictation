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
    /// The Settings scene, which has no id of its own: the name its hooks use.
    public static let settingsWindowID = "settings"

    public let pipeline: DictationPipeline
    public let service: TranscriptionService
    public let store: TranscriptStore
    /// The main window's transcripts: what is listed and selected.
    public let library: LibraryModel
    /// Danny's own words and replacement rules, edited in the Vocabulary section.
    public let vocabulary: VocabularyStore
    public let permissions: PermissionManager
    public let hotkeys: HotkeyManager
    /// Every model, as last listed by `refreshModels()`.
    public private(set) var models: [ModelDescriptor] = []
    /// The model dictation uses, as last listed; nil until then.
    public private(set) var selectedModel: ModelID?
    /// How far each download this app started has got, 0 to 1. Only models
    /// downloading now are here.
    public private(set) var downloadProgress: [ModelID: Double] = [:]
    /// A short note for a model's row in the Models section: why its last
    /// download, delete or switch failed. Cleared when the next one starts.
    public private(set) var modelMessages: [ModelID: String] = [:]
    /// The key that dictates, as saved, which the window names. The event
    /// tap took it when it started (`makeHotkeyStrategy`).
    public var hotkey: HotkeyChoice { preferences.hotkey }
    /// Whether a double tap of the hotkey locks a recording, as saved.
    public var handsFreeEnabled: Bool { preferences.handsFreeEnabled }
    /// The downloads under way, which Cancel cancels.
    @ObservationIgnored private var downloads: [ModelID: Task<Bool, Never>] = [:]
    /// The state each row's note was made in.
    @ObservationIgnored private var noteStates: [ModelID: ModelDescriptor.State] = [:]
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
    /// the microphone, the paste, the on-device cleaner, and the store with
    /// its kept recordings in `~/Library/Application Support/VoiceDictation/`.
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
            indicator: IndicatorPanel(),
            cleaner: FoundationModelCleaner()
        )
    }

    /// Connects the parts, with no side effects: `start()` asks for
    /// permissions and arms the hotkey. Tests pass fakes, an in-memory store
    /// and preferences kept in memory; with no cleaner, nothing is cleaned up.
    init(service: TranscriptionService, recorder: Recording, paster: Pasting, store: TranscriptStore,
         preferences: PreferencesManager, comparison: ComparisonRecordings, dataDirectory: URL,
         onboardingSystem: OnboardingSystem? = nil, indicator: IndicatorPresenting? = nil,
         pasteAgain: PasteAgainSystem? = nil, cleaner: TextCleaner? = nil) {
        // Once, at launch, before any view asks for Jost, Work Sans or DM Mono.
        Fonts.registerAll()
        self.service = service
        // One vocabulary for dictation and re-transcription alike (Ruling T22-2).
        let vocabulary = VocabularyStore(fileURL: dataDirectory.appendingPathComponent("vocabulary.json"))
        self.vocabulary = vocabulary
        // Paste last pastes the store's latest transcript, edits included
        // (Ruling P4); the pipeline owns no store.
        self.pipeline = DictationPipeline(recorder: recorder, service: service, paster: paster,
                                          cleaner: cleaner, replacements: { vocabulary.activeReplacements },
                                          vocabulary: { vocabulary.activeWords },
                                          cleanupEnabled: { preferences.cleanupEnabled },
                                          latestText: { store.latest?.text })
        self.store = store
        self.library = LibraryModel(store: store, service: service, paster: paster,
                                    vocabulary: { vocabulary.activeWords },
                                    replacements: { vocabulary.activeReplacements },
                                    hotkey: { preferences.hotkey },
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
        // A cleanup that came back after its raw text pasted: kept beside it.
        pipeline.onLateCleanup = { [weak self] id, cleanedText, seconds in
            self?.store.setLateCleanup(id: id, cleanedText: cleanedText, seconds: seconds)
        }
        // No outcome, but the engine did transcribe the clip (Ruling T9-2).
        pipeline.onNothingHeard = { [weak self] clip, endedAt, engineText in
            self?.comparisonRecordings.keep(clip, rawText: engineText, date: endedAt)
        }
        listModelsWhenAMenuOpens()
        observeStateForIndicator()
        observeLevelForIndicator()
    }

    /// Starts the app; called once, when launching has finished. Imports the
    /// old history, asks for missing permissions, arms the hotkey and loads
    /// the model dictation uses and the cleanup model.
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

        // Loads the cleanup model, off the main thread, so a dictation soon
        // after launch is not slowed by the load. The pipeline readies it
        // again when the hotkey goes down and after each dictation.
        pipeline.prewarmCleanup()

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

    /// Lists every model again, and the one dictation uses. A model this app
    /// is downloading reads as downloading, with the progress it has.
    public func refreshModels() async {
        let models = await service.allModels()
        let selected = await service.selected
        self.models = models.map { model in
            guard downloads[model.id] != nil else { return model }
            var downloading = model
            downloading.state = .downloading(downloadProgress[model.id] ?? 0)
            return downloading
        }
        self.selectedModel = selected
        // A note belongs to the state the model was in when it was made.
        for (id, state) in noteStates where self.models.first(where: { $0.id == id })?.state != state {
            modelMessages[id] = nil
            noteStates[id] = nil
        }
    }

    private func clearNote(on id: ModelID) {
        modelMessages[id] = nil
        noteStates[id] = nil
    }

    /// Notes `text` on a model's row, until its state changes.
    private func note(_ text: String, on id: ModelID) {
        modelMessages[id] = text
        noteStates[id] = models.first { $0.id == id }?.state
    }

    /// Makes `model` the one dictation uses and remembers the choice. The
    /// pipeline shows the progress, and a failure, which leaves the choice
    /// as it was and is noted on the model's row too. Never downloads.
    func use(_ model: ModelDescriptor) async {
        clearNote(on: model.id)
        var failure: String?
        do {
            try await pipeline.selectModel(model.id, named: model.displayName)
            preferences.selectedModelID = model.id
        } catch {
            failure = Self.message(for: error)
        }
        await refreshModels()
        if let failure { note(failure, on: model.id) }
    }

    /// The menu bar's choice, and the same two operations as the Models
    /// section (Ruling T20-1): a model not on the Mac is downloaded first,
    /// which Danny can watch and cancel in the section; a cancelled or
    /// failed download selects nothing. The status line shows the model
    /// preparing meanwhile, and a failed download shows as an error there.
    func choose(_ model: ModelDescriptor) async {
        let id = model.id
        await pipeline.whilePreparing(model.displayName) {
            if model.state == .notDownloaded || downloads[id] != nil {
                guard await download(id) else {
                    if let reason = modelMessages[id] { pipeline.showModelFailure(reason) }
                    return
                }
            }
            await use(model)
        }
    }

    /// Downloads a model. Never changes the one in use (Ruling P8). Returns
    /// whether the download finished; a second call for a model already
    /// downloading joins it. A cancel is no failure and leaves no note.
    @discardableResult
    func download(_ id: ModelID) async -> Bool {
        if let running = downloads[id] { return await running.value }
        clearNote(on: id)
        downloadProgress[id] = 0
        let service = service
        let task = Task { [self] () -> Bool in
            var finished = false
            var failure: String?
            do {
                try await service.download(id) { [weak self] fraction in
                    Task { @MainActor in self?.downloadProgressed(id, to: fraction) }
                }
                finished = true
            } catch {
                if !Task.isCancelled, !(error is CancellationError) { failure = Self.message(for: error) }
            }
            downloads[id] = nil
            downloadProgress[id] = nil
            await refreshModels()
            if let failure { note(failure, on: id) }
            return finished
        }
        downloads[id] = task
        await refreshModels()
        return await task.value
    }

    /// Cancels the download's task; the engine removes what it had fetched
    /// and the row goes back to Not downloaded once it has (Ruling T20-2).
    func cancelDownload(_ id: ModelID) {
        downloads[id]?.cancel()
    }

    /// Deletes a model's files. The one in use, one still preparing and the
    /// Apple models, which macOS manages, are refused; the row says why.
    func deleteModel(_ id: ModelID) async {
        clearNote(on: id)
        var failure: String?
        do {
            try await service.delete(id)
        } catch {
            failure = Self.message(for: error)
        }
        await refreshModels()
        if let failure { note(failure, on: id) }
    }

    private func downloadProgressed(_ id: ModelID, to fraction: Double) {
        // Late reports of a finished or cancelled download are ignored.
        guard downloads[id] != nil else { return }
        downloadProgress[id] = max(fraction, downloadProgress[id] ?? 0)
        if let index = models.firstIndex(where: { $0.id == id }) {
            models[index].state = .downloading(downloadProgress[id] ?? 0)
        }
    }

    private static func message(for error: Error) -> String {
        DictationPipeline.describe(error)
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
        let strategy = makeHotkeyStrategy()
        hotkeys.start(strategy: strategy)
        isListening = true
        Log.info("[START] Listening for \(strategy.choice.displayName) key")
    }

    /// The hotkey's event tap, as the preferences have it. The key is read
    /// now, so another choice takes a new tap (`HotkeyManager.start` again);
    /// hands-free and the Paste last shortcut are read at each press, and
    /// what the pipeline is doing at each key. No tap exists until it starts.
    func makeHotkeyStrategy() -> ModifierKeyStrategy {
        let preferences = preferences
        return ModifierKeyStrategy(choice: preferences.hotkey,
                                   handsFree: { preferences.handsFreeEnabled },
                                   pasteLastShortcut: { preferences.pasteLastHotkeyEnabled },
                                   appState: { [weak self] in self?.pipeline.state ?? .idle })
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

    /// The hotkey's own cancel: a key pressed with the hotkey held cancels
    /// this hold's dictation and nothing else.
    public func hotkeyCancelled() {
        pipeline.cancelHold()
    }

    /// A lone tap with hands-free on is no dictation.
    public func hotkeyDidTap() {
        pipeline.discardTap()
    }

    /// Escape's cancel: everything the pipeline is doing, not just a hold.
    public func escapePressedWhileWorking() {
        pipeline.cancel()
    }

    public func pasteLastShortcutPressed() {
        pipeline.pasteLast()
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
        activation = .live
        super.init()
    }

    /// What the app does to its activation policy and focus; tests stand in.
    let activation: AppActivation
    /// The windows that Paste again hid, reported closed, and whose return
    /// has not yet been reported (Ruling T19-5).
    private var hiddenByPasteAgain: Set<String> = []

    /// Tests pass a model built from fakes, and a stand-in for AppKit.
    init(model: AppModel, activation: AppActivation = .live) {
        self.activation = activation
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

    /// A window (the main one, Welcome or Settings) has opened: a Dock icon
    /// and the app's own menu bar, as for any app with a window. One decision
    /// for every window: the return of a window Paste again hid is no
    /// opening, and asks for neither the policy change nor the activation
    /// (Ruling T19-5), which would take the keyboard from the app just
    /// pasted into. The main window's library hears of real openings only.
    public func windowDidOpen(_ id: String) {
        guard hiddenByPasteAgain.remove(id) == nil else { return }
        if id == AppModel.mainWindowID { model.library.windowOpened() }
        activation.setRegularPolicy()
        activation.activate()
    }

    /// A window has closed. While Paste again runs and the app is hidden
    /// that is only the hide, remembered so the window's return is
    /// recognised, and nothing else happens. A close while the app is not
    /// hidden, even during the run, is Danny's: a real close. Inside
    /// `onDisappear` the closing window may still report itself visible, so
    /// the windows are counted a turn later. With none left the app returns
    /// to the menu bar only and hides, handing focus back to the app that
    /// was in front: a dictation made while this app was active with no
    /// window would paste nowhere.
    public func windowDidClose(_ id: String) {
        guard !(model.library.isPastingAgain && activation.isHidden()) else {
            hiddenByPasteAgain.insert(id)
            return
        }
        hiddenByPasteAgain.remove(id)
        if id == AppModel.mainWindowID { model.library.windowClosed() }
        let activation = activation
        DispatchQueue.main.async {
            guard WindowPolicy.afterClose(windows: activation.windows()) == .leaveAndHide else { return }
            activation.setAccessoryPolicy()
            activation.hide()
        }
    }
}

/// The app's calls on `NSApp` for policy, focus and windows, as closures so
/// tests can record them and never touch the real application.
struct AppActivation {
    var setRegularPolicy: @MainActor () -> Void
    var setAccessoryPolicy: @MainActor () -> Void
    var activate: @MainActor () -> Void
    var hide: @MainActor () -> Void
    /// Whether the app is hidden (`NSApp.isHidden`), as Paste again leaves it.
    var isHidden: @MainActor () -> Bool
    var windows: @MainActor () -> [WindowSnapshot]

    static let live = {
        AppActivation(
            setRegularPolicy: { NSApp.setActivationPolicy(.regular) },
            setAccessoryPolicy: { NSApp.setActivationPolicy(.accessory) },
            activate: { NSApp.activate() },
            hide: { NSApp.hide(nil) },
            isHidden: { NSApp.isHidden },
            windows: {
                NSApp.windows.map { WindowSnapshot(isVisible: $0.isVisible, isMiniaturized: $0.isMiniaturized, canBecomeMain: $0.canBecomeMain) }
            })
    }()
}
