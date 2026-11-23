import AppKit
import Carbon.HIToolbox
import XCTest
@testable import VoiceDictationLib
@testable import VoiceDictationUI

/// The wiring `AppModel` took over from `AppDelegate`, built from fakes: no
/// microphone, no event tap, an in-memory store, preferences in memory and
/// a temporary data folder. `start()` is called only to see the mini view
/// turned on at launch: it checks permissions, and the hotkey it arms is the
/// fake's, which makes no event tap.
final class AppModelTests: XCTestCase {
    private let recorder = FakeRecorder()
    private let paster = FakePaster()
    private let defaults = MemoryPreferenceStore()
    private lazy var preferences = PreferencesManager(defaults: defaults)
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vd-appmodel-\(UUID().uuidString)", isDirectory: true)
    /// Where Task 2's comparison switch kept its clips, in the data folder.
    private var comparisonDirectory: URL { directory.appendingPathComponent("comparison", isDirectory: true) }
    private let tiny = ModelID(engine: .whisperKit, name: "openai_whisper-tiny.en")

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Models

    @MainActor
    func testRefreshListsEveryModelAndTheOneInUse() async {
        let apple = FakeEngine(kind: .appleSpeech, models: [descriptor(.appleSpeech, .ready),
                                                            descriptor(.appleDictation, .notDownloaded)])
        let whisperKit = FakeEngine(kind: .whisperKit, models: [descriptor(tiny, .ready)])
        let model = makeModel([apple, whisperKit], selected: .appleDictation)
        XCTAssertTrue(model.models.isEmpty)
        XCTAssertNil(model.selectedModel)

        await model.refreshModels()

        XCTAssertEqual(model.models.map(\.id), [.appleSpeech, .appleDictation, tiny])
        XCTAssertEqual(model.selectedModel, .appleDictation)
    }

    /// Ruling T9-3: the Model submenu is listed again whenever a menu opens,
    /// so its states and checkmark are current.
    @MainActor
    func testOpeningAMenuListsTheModelsAgain() async throws {
        let apple = FakeEngine(kind: .appleSpeech, models: [descriptor(.appleSpeech, .notDownloaded)])
        let model = makeModel([apple])
        await model.refreshModels()

        apple.modelList = [descriptor(.appleSpeech, .ready)]
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())

        try await waitUntil("the model shows as ready") { model.models.first?.state == .ready }
    }

    @MainActor
    func testChoosingAModelUsesAndSavesIt() async {
        let model = makeModel([appleEngine(), FakeEngine(kind: .whisperKit, models: [descriptor(tiny, .ready)])])

        await model.choose(descriptor(tiny, .ready))

        XCTAssertEqual(preferences.selectedModelID, tiny)
        XCTAssertEqual(model.selectedModel, tiny)
        let inUse = await model.service.selected
        XCTAssertEqual(inUse, tiny)
    }

    /// The pipeline shows the failure; the saved choice stays as it was.
    @MainActor
    func testAChoiceThatCannotLoadIsNotSaved() async {
        let whisperKit = FakeEngine(kind: .whisperKit, models: [descriptor(tiny, .ready)])
        whisperKit.unloadable = [tiny]
        preferences.selectedModelID = .appleSpeech
        let model = makeModel([appleEngine(), whisperKit])

        await model.choose(descriptor(tiny, .ready))

        XCTAssertEqual(preferences.selectedModelID, .appleSpeech)
        XCTAssertEqual(model.selectedModel, .appleSpeech)
    }

    /// "Download Apple Dictation" downloads it, then makes it the model in use.
    @MainActor
    func testChoosingANotDownloadedModelDownloadsItFirst() async {
        let apple = appleEngine()
        let model = makeModel([apple])

        await model.choose(descriptor(.appleDictation, .notDownloaded))

        XCTAssertEqual(apple.calls.filter { $0 != .prepare(.appleSpeech) },
                       [.download(.appleDictation), .prepare(.appleDictation)])
        XCTAssertEqual(preferences.selectedModelID, .appleDictation)
    }

    // MARK: - Dictations

    /// Every finished dictation reaches the store (Task 11).
    @MainActor
    func testEveryDictationIsKept() async throws {
        let model = makeModel([appleEngine()])

        model.hotkeyDidStartPress()
        model.hotkeyDidEndPress()

        try await waitUntil("the transcript is kept") { !model.store.search("", scope: .all).isEmpty }
        XCTAssertEqual(paster.pasted, ["Hello there."])
        let transcript = try XCTUnwrap(model.store.search("", scope: .all).first)
        XCTAssertEqual(transcript.text, "Hello there.")
        XCTAssertEqual(transcript.status, .pasted)
        // The first pasted dictation completes the Welcome window's last step.
        XCTAssertEqual(model.onboarding.state(of: .tryIt), .done)
    }

    /// Task 24: kept recordings replace the comparison switch, so the switch,
    /// still set from before, writes nothing. The clips already in the
    /// comparison folder stay where they are: `vd-bench` still reads them.
    @MainActor
    func testTheOldComparisonSwitchKeepsNothingAndLeavesTheFolderAlone() async throws {
        defaults.set(true, forKey: "keepComparisonRecordings")
        try FileManager.default.createDirectory(at: comparisonDirectory, withIntermediateDirectories: true)
        let oldClip = comparisonDirectory.appendingPathComponent("1762900000000.wav")
        try AudioClip(samples: [Float](repeating: 0.2, count: 1_600)).writeWAV(to: oldClip)
        let before = try Data(contentsOf: oldClip)
        let model = makeModel([appleEngine()])

        model.hotkeyDidStartPress()
        model.hotkeyDidEndPress()

        try await waitUntil("the transcript is kept") { !model.store.search("", scope: .all).isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(comparisonFiles(), ["1762900000000.wav"], "the switch wrote a clip")
        XCTAssertEqual(try Data(contentsOf: oldClip), before)
    }

    /// Task 21: a cleanup in time is kept with the raw text it replaced; one
    /// that comes back after the paste reaches the store too, through
    /// `onLateCleanup`, beside the pasted raw text, for "Use cleaned".
    /// Nothing is pasted twice.
    @MainActor
    func testCleanupsInTimeAndLateAreKept() async throws {
        let engine = appleEngine()
        engine.result = "um so ship the new build"
        let cleaner = FakeCleaner()
        cleaner.reply = { _ in "So ship the new build." }
        let model = makeModel([engine], cleaner: cleaner)

        model.hotkeyDidStartPress()
        model.hotkeyDidEndPress()
        try await waitUntil("the cleaned dictation is kept") { model.store.search("", scope: .all).count == 1 }
        let inTime = try XCTUnwrap(model.store.search("", scope: .all).first)
        XCTAssertEqual(inTime.text, "So ship the new build.")
        XCTAssertEqual(inTime.rawText, "um so ship the new build")
        XCTAssertEqual(inTime.cleanedText, "So ship the new build.")
        XCTAssertNotNil(inTime.cleanupSeconds)

        model.pipeline.cleanupLimitSeconds = 0.1
        cleaner.delay = 0.4
        model.hotkeyDidStartPress()
        model.hotkeyDidEndPress()
        try await waitUntil("the raw text is kept") { model.store.search("", scope: .all).count == 2 }
        let late = try XCTUnwrap(model.store.search("", scope: .all).first { $0.id != inTime.id })
        XCTAssertEqual(late.text, "um so ship the new build")
        XCTAssertNil(late.cleanedText)
        try await waitUntil("the late cleanup is kept") { late.cleanedText != nil }

        XCTAssertEqual(late.cleanedText, "So ship the new build.")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(late.cleanupSeconds), 0.4)
        XCTAssertEqual(late.text, "um so ship the new build", "the pasted text stays the main text")
        XCTAssertTrue(LibraryModel.offersUseCleaned(late))
        XCTAssertEqual(paster.pasted, ["So ship the new build.", "um so ship the new build"])
    }

    /// With the window open its list shows a dictation as soon as it is
    /// kept, selected when nothing else was. Closed, the library does no
    /// work for it; the window lists it when it opens.
    @MainActor
    func testADictationAppearsInTheLibrary() async throws {
        let model = makeModel([appleEngine()])
        model.library.windowOpened()
        XCTAssertTrue(model.library.rows.isEmpty)

        model.hotkeyDidStartPress()
        model.hotkeyDidEndPress()

        try await waitUntil("the transcript is listed") { !model.library.rows.isEmpty }
        XCTAssertEqual(model.library.rows.map(\.text), ["Hello there."])
        XCTAssertEqual(model.library.selection, model.library.rows.first?.id)
        XCTAssertEqual(model.store.search("", scope: .all).count, 1, "kept once")
    }

    /// Task 22: the app's vocabulary store feeds dictation. Its words reach
    /// the engine, its rules change the text, and it lives in the data folder.
    @MainActor
    func testTheVocabularyReachesDictation() async throws {
        let apple = appleEngine()
        apple.result = "set up tail scale"
        let model = makeModel([apple])
        model.vocabulary.words = ["Tailscale", " "]
        model.vocabulary.replacements = [Replacement(from: "tail scale", to: "Tailscale")]
        model.vocabulary.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("vocabulary.json").path))

        model.hotkeyDidStartPress()
        model.hotkeyDidEndPress()
        try await waitUntil("it is pasted") { !paster.pasted.isEmpty }

        XCTAssertEqual(apple.vocabularies, [["Tailscale"]])
        XCTAssertEqual(paster.pasted, ["set up Tailscale"])
    }

    /// Ruling T22-3: the transcript keeps the replaced text as its raw text.
    @MainActor
    func testTheTranscriptKeepsTheReplacedText() async throws {
        let apple = appleEngine()
        apple.result = "my gv seventy"
        let model = makeModel([apple])
        model.vocabulary.replacements = [Replacement(from: "gv seventy", to: "GV70")]

        model.hotkeyDidStartPress()
        model.hotkeyDidEndPress()

        try await waitUntil("the transcript is kept") { !model.store.search("", scope: .all).isEmpty }
        XCTAssertEqual(try XCTUnwrap(model.store.search("", scope: .all).first).rawText, "my GV70")
    }

    /// The window's actions use the app's own parts: Copy goes through the
    /// paster dictation uses (a fake here, never the clipboard).
    @MainActor
    func testTheLibraryCopiesThroughTheAppsPaster() async throws {
        let model = makeModel([appleEngine()])
        model.library.windowOpened()
        model.hotkeyDidStartPress()
        model.hotkeyDidEndPress()
        try await waitUntil("the transcript is listed") { !model.library.rows.isEmpty }
        let transcript = try XCTUnwrap(model.library.rows.first)

        model.library.copy(transcript)

        XCTAssertEqual(paster.copied, ["Hello there."])
        XCTAssertEqual(paster.pasted, ["Hello there."], "only the dictation itself was pasted")
    }

    @MainActor
    func testADictationMadeWithTheWindowClosedIsListedWhenItOpens() async throws {
        let model = makeModel([appleEngine()])
        model.library.windowOpened()
        model.library.windowClosed()

        model.hotkeyDidStartPress()
        model.hotkeyDidEndPress()

        try await waitUntil("the transcript is kept") { !model.store.search("", scope: .all).isEmpty }
        XCTAssertTrue(model.library.rows.isEmpty, "not listed while closed")
        model.library.windowOpened()
        XCTAssertEqual(model.library.rows.map(\.text), ["Hello there."])
        XCTAssertEqual(model.library.selection, model.library.rows.first?.id)
    }

    // MARK: - Welcome window

    /// The model list is empty until the first refresh; the launch decision
    /// must wait for it, or every launch would open the window.
    @MainActor
    func testNothingLeftMeansNoWelcomeAtLaunch() async {
        preferences.onboardingTriedIt = true
        let model = makeModel([appleEngine()])
        XCTAssertTrue(model.models.isEmpty)

        await model.decideWelcomeAtLaunch(firstLaunch: false)

        XCTAssertEqual(model.welcomeRequests, 0)
    }

    @MainActor
    func testAStepLeftOrAFirstRunAsksForTheWelcomeWindow() async {
        preferences.onboardingTriedIt = true
        let missing = makeModel([appleEngine()], system: .fake(accessibility: false))
        await missing.decideWelcomeAtLaunch(firstLaunch: false)
        XCTAssertEqual(missing.welcomeRequests, 1)

        let first = makeModel([appleEngine()])
        await first.decideWelcomeAtLaunch(firstLaunch: true)
        XCTAssertEqual(first.welcomeRequests, 1)
    }

    @MainActor
    func testAModelStillPreparingAtLaunchDoesNotAskForTheWelcomeWindow() async {
        preferences.onboardingTriedIt = true
        let apple = FakeEngine(kind: .appleSpeech, models: [descriptor(.appleSpeech, .preparing)])
        let model = makeModel([apple])
        await model.decideWelcomeAtLaunch(firstLaunch: false)
        XCTAssertEqual(model.welcomeRequests, 0)
    }

    /// Final fix wave, E1 (Ruling T20-1): the Welcome window's Download is the
    /// app's own download, so the step and the Models section show the same
    /// progress, and the section's Cancel stops it. A cancel is no failure:
    /// the step offers Download again, with nothing said.
    @MainActor
    func testTheWelcomeDownloadIsTheAppsAndItsCancelStopsIt() async throws {
        let apple = FakeEngine(kind: .appleSpeech, models: [appleSpeechRow(.notDownloaded)])
        apple.onDownload = { _, progress in
            progress(0.42)
            try await Task.sleep(for: .seconds(60))
        }
        let model = makeModel([apple])
        await model.refreshModels()

        let download = Task { await model.onboarding.downloadSelectedModel() }
        try await waitUntil("the Models section shows the download") { model.downloadProgress[.appleSpeech] == 0.42 }
        XCTAssertEqual(model.onboarding.step(.speechModel).detail, "Downloading… 42%")
        let row = try XCTUnwrap(model.models.first { $0.id == .appleSpeech })
        XCTAssertEqual(ModelsView.actions(for: row, selected: model.selectedModel,
                                          cancellable: model.downloadProgress[.appleSpeech] != nil), [.cancel])

        model.cancelDownload(.appleSpeech)
        await download.value

        XCTAssertNil(model.downloadProgress[.appleSpeech])
        XCTAssertNil(model.modelMessages[.appleSpeech], "a cancel is not an error")
        XCTAssertEqual(model.onboarding.step(.speechModel).detail, "The Apple Speech model needs its files before it can listen.")
        XCTAssertEqual(model.onboarding.step(.speechModel).actionTitle, "Download the Apple Speech model")
    }

    /// Final fix wave, E1: a failed Welcome download says why in plain words,
    /// the engine's own, as the Models section's row does; never "The
    /// operation couldn't be completed…".
    @MainActor
    func testAFailedWelcomeDownloadSaysWhyInPlainWords() async {
        let apple = FakeEngine(kind: .appleSpeech, models: [appleSpeechRow(.notDownloaded)])
        apple.onDownload = { _, _ in
            throw TranscriptionError.failed("Apple Speech language files could not be installed: No network")
        }
        let model = makeModel([apple])
        await model.refreshModels()

        await model.onboarding.downloadSelectedModel()

        XCTAssertEqual(model.onboarding.step(.speechModel).detail,
                       "The download failed: Apple Speech language files could not be installed: No network")
        XCTAssertEqual(model.modelMessages[.appleSpeech], "Apple Speech language files could not be installed: No network")
    }

    // MARK: - The main window at launch (Danny, 2026-11-20)

    /// Opened by Danny, with nothing left to set up: the main window.
    @MainActor
    func testALaunchByHandAsksForTheMainWindow() async {
        preferences.onboardingTriedIt = true
        let model = makeModel([appleEngine()])

        await model.decideWelcomeAtLaunch(firstLaunch: false, launchedAtLogin: false)

        XCTAssertEqual(model.mainWindowRequests, 1)
        XCTAssertEqual(model.welcomeRequests, 0)
    }

    /// Started by macOS at login: no window, the menu bar only.
    @MainActor
    func testALaunchAtLoginAsksForNoWindow() async {
        preferences.onboardingTriedIt = true
        let model = makeModel([appleEngine()])

        await model.decideWelcomeAtLaunch(firstLaunch: false, launchedAtLogin: true)

        XCTAssertEqual(model.mainWindowRequests, 0)
        XCTAssertEqual(model.welcomeRequests, 0)
    }

    /// A setup step left: Welcome alone, at login too, never both windows.
    @MainActor
    func testWelcomeComesBeforeTheMainWindow() async {
        preferences.onboardingTriedIt = true
        let model = makeModel([appleEngine()], system: .fake(accessibility: false))

        await model.decideWelcomeAtLaunch(firstLaunch: false, launchedAtLogin: false)

        XCTAssertEqual(model.welcomeRequests, 1)
        XCTAssertEqual(model.mainWindowRequests, 0)
    }

    /// Opening the app again while it runs asks for the main window, and
    /// each request is served once.
    @MainActor
    func testOpeningTheRunningAppAsksForTheMainWindowOnce() {
        let model = makeModel([appleEngine()])
        let lifecycle = AppLifecycle(model: model)
        XCTAssertFalse(model.takeMainWindowRequest())

        _ = lifecycle.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)

        XCTAssertEqual(model.mainWindowRequests, 1)
        XCTAssertTrue(model.takeMainWindowRequest())
        XCTAssertFalse(model.takeMainWindowRequest())
    }

    /// The icon can appear again (its image changes with the state); only
    /// the first sight after a request may open the window.
    @MainActor
    func testOneWelcomeRequestIsServedOnce() async {
        let model = makeModel([appleEngine()])
        XCTAssertFalse(model.takeWelcomeRequest())
        await model.decideWelcomeAtLaunch(firstLaunch: true)
        XCTAssertTrue(model.takeWelcomeRequest())
        XCTAssertFalse(model.takeWelcomeRequest())
        XCTAssertFalse(model.takeWelcomeRequest())
    }

    /// A dictation whose text came back empty pastes nothing and is no
    /// transcript. Since Task 24 nothing else keeps it either: Ruling T9-2's
    /// comparison clip went with the comparison switch.
    @MainActor
    func testAnEmptyTextIsNotKept() async throws {
        let apple = appleEngine()
        apple.result = ""
        let model = makeModel([apple])

        model.hotkeyDidStartPress()
        model.hotkeyDidEndPress()

        try await waitUntil("the dictation is transcribed") { apple.calls.contains(.transcribe(.appleSpeech)) }
        try await waitUntil("the app is idle") { model.pipeline.state == .idle }
        XCTAssertTrue(model.store.search("", scope: .all).isEmpty)
        XCTAssertTrue(paster.pasted.isEmpty)
        XCTAssertEqual(comparisonFiles(), [])
    }

    /// A key pressed with the Globe key cancels only that hold's dictation
    /// (`cancelHold`), never one made before it, which `cancel()` would.
    @MainActor
    func testHotkeyCancelNeverReachesAnEarlierDictation() async throws {
        let apple = appleEngine()
        apple.isHeld = true
        let model = makeModel([apple])
        model.hotkeyDidStartPress()
        model.hotkeyDidEndPress()
        try await waitUntil("the dictation is being transcribed") { apple.calls.contains(.transcribe(.appleSpeech)) }

        model.hotkeyCancelled()
        apple.isHeld = false

        try await waitUntil("the earlier dictation still pastes") { self.paster.pasted == ["Hello there."] }
        XCTAssertEqual(model.store.search("", scope: .all).count, 1)
    }

    // MARK: - The hotkey (Task 23)

    /// Escape while the app works is Escape's cancel, `cancel()`: unlike the
    /// hotkey's own cancel it reaches the dictation being transcribed, which
    /// then leaves no trace.
    @MainActor
    func testEscapeWhileWorkingCancelsTheDictationInLine() async throws {
        let apple = appleEngine()
        apple.isHeld = true
        let model = makeModel([apple])
        model.hotkeyDidStartPress()
        model.hotkeyDidEndPress()
        try await waitUntil("the dictation is being transcribed") { apple.calls.contains(.transcribe(.appleSpeech)) }

        model.escapePressedWhileWorking()
        XCTAssertEqual(model.pipeline.state, .idle)
        apple.isHeld = false
        // Time for a stray paste or transcript to show up.
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(paster.pasted, [])
        XCTAssertTrue(model.store.search("", scope: .all).isEmpty, "a cancelled dictation is not kept")
    }

    /// A lone tap with double-tap dictation on is no dictation: its
    /// recording is thrown away, and nothing is pasted or kept.
    @MainActor
    func testATapThrowsItsRecordingAway() async throws {
        let model = makeModel([appleEngine()])
        model.hotkeyDidStartPress()
        XCTAssertTrue(recorder.isRecording)

        model.hotkeyDidTap()

        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(model.pipeline.state, .idle)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(paster.pasted, [])
        XCTAssertTrue(model.store.search("", scope: .all).isEmpty)
    }

    /// Control-Option-V pastes the latest transcript, as the menu item does.
    @MainActor
    func testThePasteLastShortcutPastesTheLatestTranscript() async throws {
        let model = makeModel([appleEngine()])
        model.hotkeyDidStartPress()
        model.hotkeyDidEndPress()
        try await waitUntil("the transcript is kept") { model.store.latest != nil }

        model.pasteLastShortcutPressed()

        XCTAssertEqual(paster.pasted, ["Hello there.", "Hello there."])
    }

    /// The tap the app arms follows the preferences: the key saved when it is
    /// made, and double-tap dictation and the Paste last shortcut as they are
    /// at each press. At each key it reads the work under way
    /// (`DictationPipeline.work`), not what the menu bar shows (final fix
    /// wave, item A). Making one creates no event tap; only `start()` does.
    @MainActor
    func testTheHotkeyFollowsThePreferences() {
        preferences.hotkey = .rightCommand
        let model = makeModel([appleEngine()])

        let strategy = model.makeHotkeyStrategy()

        XCTAssertEqual(strategy.choice, .rightCommand)
        XCTAssertFalse(strategy.doubleTap())
        XCTAssertFalse(strategy.pasteLastShortcut())
        preferences.doubleTapEnabled = true
        preferences.pasteLastHotkeyEnabled = true
        XCTAssertTrue(strategy.doubleTap())
        XCTAssertTrue(strategy.pasteLastShortcut())
        XCTAssertEqual(strategy.appState(), .idle)
        model.pipeline.missingPermission = "Microphone"
        XCTAssertEqual(model.pipeline.state, .needsPermission("Microphone"), "the menu bar shows it")
        XCTAssertEqual(strategy.appState(), .idle, "nothing is under way")
        model.hotkeyDidStartPress()
        guard case .recording = strategy.appState() else { return XCTFail("the tap reads \(strategy.appState())") }
    }

    // MARK: - Permissions

    /// Final fix wave, E3: microphone access granted while the app runs (the
    /// Welcome window's first-run grant, say) readies the microphone at once.
    /// `prepare()` does nothing without access, so otherwise the first
    /// dictation would build it at key-down. A report that changes nothing
    /// for the microphone readies nothing.
    @MainActor
    func testGrantingTheMicrophoneReadiesIt() {
        let model = makeModel([appleEngine()])
        let readied = recorder.prepareCount
        model.permissionStatusChanged(accessibility: false, microphone: false)
        XCTAssertEqual(recorder.prepareCount, readied, "no access yet")

        model.permissionStatusChanged(accessibility: false, microphone: true)
        XCTAssertEqual(recorder.prepareCount, readied + 1, "access granted: readied at once")

        model.permissionStatusChanged(accessibility: true, microphone: true)
        XCTAssertEqual(recorder.prepareCount, readied + 1, "only Accessibility changed")
        model.permissionStatusChanged(accessibility: true, microphone: false)
        model.permissionStatusChanged(accessibility: true, microphone: true)
        XCTAssertEqual(recorder.prepareCount, readied + 2, "taken away and granted again: readied again")
    }

    // MARK: - Paste last (Ruling P4)

    /// Paste last pastes the store's latest transcript as it reads now: an
    /// edit made in the window, not the text that was pasted, and never a
    /// newer failed dictation, which has no text. With nothing kept there is
    /// nothing to paste, and the menu item is off.
    @MainActor
    func testPasteLastUsesLatestTranscript() async throws {
        let model = makeModel([appleEngine()])
        XCTAssertFalse(model.pipeline.canPasteLast)
        model.pipeline.pasteLast()
        XCTAssertEqual(paster.pasted, [], "nothing kept yet")

        model.hotkeyDidStartPress()
        model.hotkeyDidEndPress()
        try await waitUntil("the transcript is kept") { model.store.latest != nil }
        let transcript = try XCTUnwrap(model.store.latest)
        model.store.updateText(transcript, "Hello there, Danny.")
        XCTAssertNotNil(model.store.add(DictationOutcome(
            date: Date().addingTimeInterval(60), clip: nil, rawText: "", text: "", model: .appleSpeech,
            transcribeSeconds: 0, appName: "TextEdit", status: .failed, failure: "Apple Speech language files are not installed")))
        XCTAssertTrue(model.pipeline.canPasteLast)

        model.pipeline.pasteLast()

        XCTAssertEqual(paster.pasted, ["Hello there.", "Hello there, Danny."])
        XCTAssertEqual(model.store.search("", scope: .all).count, 2, "pasting again keeps nothing new")
    }

    // MARK: - The indicator

    /// "Listening" while the key is held, "Transcribing" after, then gone
    /// once the text is pasted.
    @MainActor
    func testTheIndicatorShowsWhileADictationRunsThenHides() async throws {
        let apple = appleEngine()
        apple.isHeld = true
        let indicator = FakeIndicator()
        let model = makeModel([apple], indicator: indicator)

        model.hotkeyDidStartPress()
        try await waitUntil("it shows Listening") { indicator.showsListening }
        model.hotkeyDidEndPress()
        try await waitUntil("it shows Transcribing") { indicator.isShowing && indicator.state == .transcribing }
        apple.isHeld = false
        try await waitUntil("it hides once the text is pasted") { !indicator.isShowing }
        XCTAssertEqual(paster.pasted, ["Hello there."])
    }

    /// Each level heard while recording goes into the line, and each
    /// recording starts a new, flat line (Ruling T17-1).
    @MainActor
    func testLevelsFeedTheLineAndEachRecordingStartsAFreshOne() async throws {
        let indicator = FakeIndicator()
        let model = makeModel([appleEngine()], indicator: indicator)

        model.hotkeyDidStartPress()
        recorder.onLevel?(0.5, ProcessInfo.processInfo.systemUptime)
        try await waitUntil("the line rises") { self.isRaised(indicator.line) }
        let first = indicator.state
        model.hotkeyDidEndPress()
        try await waitUntil("the first dictation is pasted") { self.paster.pasted.count == 1 }

        model.hotkeyDidStartPress()
        try await waitUntil("the second recording shows") { indicator.showsListening && indicator.state != first }
        XCTAssertFalse(isRaised(indicator.line))
    }

    /// Task 24A: the recorder hands over a buffer's slices together. Each goes
    /// into the line at the time it was captured: none is lost to the one
    /// after it, and none is moved to when it arrived.
    @MainActor
    func testEachSliceGoesIntoTheLineAtItsOwnTime() async throws {
        let indicator = FakeIndicator()
        let model = makeModel([appleEngine()], indicator: indicator)
        let captured = ProcessInfo.processInfo.systemUptime - 0.3

        model.hotkeyDidStartPress()
        recorder.onLevel?(0.1, captured)
        recorder.onLevel?(0.02, captured + LevelLine.interval)

        var expected = LevelLine()
        expected.add(peak: 0.1, at: captured)
        expected.add(peak: 0.02, at: captured + LevelLine.interval)
        let drawn = captured + 3 * LevelLine.interval
        try await waitUntil("both slices are in the line, each at its own time") {
            indicator.line.points(at: drawn) == expected.points(at: drawn)
        }
        XCTAssertTrue(indicator.showsListening)
    }

    // MARK: - The mini view

    /// The tab says what the pill would, so the pill stays hidden while the
    /// tab shows. The tab hears the work under way and how the dictation ended.
    @MainActor
    func testThePillStaysHiddenWhileTheTabShows() async throws {
        let apple = appleEngine()
        apple.isHeld = true
        let indicator = FakeIndicator()
        let miniView = FakeMiniView()
        miniView.isShowingTab = true
        let model = makeModel([apple], indicator: indicator, miniView: miniView)

        model.hotkeyDidStartPress()
        try await waitUntil("the tab hears of the recording") { miniView.works.contains(where: self.isRecording) }
        model.hotkeyDidEndPress()
        try await waitUntil("the tab hears of the transcribing") { miniView.works.contains(.transcribing) }
        apple.isHeld = false
        try await waitUntil("the text is pasted and the work is over") {
            self.paster.pasted == ["Hello there."] && miniView.works.last == .idle
        }

        XCTAssertFalse(indicator.everShown)
        XCTAssertTrue(miniView.works.contains(where: isRecording))
        XCTAssertEqual(miniView.outcomes.count, 1)
        XCTAssertEqual(miniView.outcomes.first?.status, .pasted)
    }

    /// With the tab hidden (no window in front, full screen, or off), the
    /// pill works as before.
    @MainActor
    func testThePillShowsWhenTheTabIsHidden() async throws {
        let apple = appleEngine()
        apple.isHeld = true
        let indicator = FakeIndicator()
        let miniView = FakeMiniView()
        let model = makeModel([apple], indicator: indicator, miniView: miniView)

        model.hotkeyDidStartPress()
        try await waitUntil("it shows Listening") { indicator.showsListening }
        model.hotkeyDidEndPress()
        try await waitUntil("it shows Transcribing") { indicator.isShowing && indicator.state == .transcribing }
        apple.isHeld = false
        try await waitUntil("it hides once the text is pasted") { !indicator.isShowing }
        XCTAssertEqual(miniView.outcomes.count, 1)
    }

    @MainActor
    func testThePillComesBackWhenTheTabHidesMidDictation() async throws {
        let indicator = FakeIndicator()
        let miniView = FakeMiniView()
        miniView.isShowingTab = true
        let model = makeModel([appleEngine()], indicator: indicator, miniView: miniView)

        model.hotkeyDidStartPress()
        try await waitUntil("the tab hears of the recording") { miniView.works.contains(where: self.isRecording) }
        XCTAssertFalse(indicator.isShowing)

        miniView.isShowingTab = false
        miniView.onTabShownOrHidden?()
        XCTAssertTrue(indicator.showsListening)

        model.hotkeyDidEndPress()
        try await waitUntil("it hides once the text is pasted") { self.paster.pasted.count == 1 && !indicator.isShowing }
    }

    /// "Mini View" in the menu is saved, and the next launch turns the mini
    /// view on again.
    @MainActor
    func testTheMiniViewSettingIsSavedAndRestored() {
        let miniView = FakeMiniView()
        let model = makeModel([appleEngine()], miniView: miniView)
        XCTAssertFalse(model.miniViewEnabled, "off by default")

        model.miniViewEnabled = true

        XCTAssertTrue(preferences.miniViewEnabled)
        XCTAssertEqual(miniView.enabledCalls, [true])
        let secondMini = FakeMiniView()
        let again = makeModel([appleEngine()], miniView: secondMini)
        again.start()
        XCTAssertEqual(secondMini.enabledCalls.last, true)
    }

    // MARK: - An error shown over work under way (final fix wave, item A)

    // In each test a dictation is in line, held in the engine, and the next
    // press finds the microphone taken: "Microphone in use by another app"
    // shows for a few seconds, over the dictation still under way.

    /// Escape still cancels the dictation in line, and is swallowed: the
    /// tap reads the work under way, not the error the menu bar shows. The
    /// app's own paste still goes through first. Nothing pastes and nothing
    /// is kept, and the error stays on show.
    @MainActor
    func testEscapeCancelsTheDictationInLineWhileAnErrorShows() async throws {
        let apple = appleEngine()
        apple.isHeld = true
        let model = makeModel([apple])
        let tap = model.makeHotkeyStrategy()
        tap.delegate = model
        try await showAnErrorOverADictationInLine(model, apple)

        XCTAssertTrue(letsThrough(tap, try keyDown(kVK_ANSI_V, flags: .maskCommand, tag: PasteEngine.eventTag)),
                      "the app's own paste goes through")
        XCTAssertFalse(letsThrough(tap, try keyDown(kVK_Escape)), "Escape is swallowed")
        try await waitUntil("Escape cancels the dictation in line") { model.pipeline.dictationsInFlight == 0 }
        apple.isHeld = false
        // Time for a stray paste or transcript to show up.
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(paster.pasted, [])
        XCTAssertTrue(model.store.search("", scope: .all).isEmpty, "a cancelled dictation is not kept")
        XCTAssertEqual(model.pipeline.state, .error("Microphone in use by another app"))
    }

    /// The indicator keeps "Transcribing" while the error shows, and hides
    /// once the dictation pastes.
    @MainActor
    func testTheIndicatorKeepsTranscribingWhileAnErrorShows() async throws {
        let apple = appleEngine()
        apple.isHeld = true
        let indicator = FakeIndicator()
        let model = makeModel([apple], indicator: indicator)
        try await showAnErrorOverADictationInLine(model, apple)
        // The indicator follows a change a turn later.
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(indicator.isShowing, "the dictation in line is still under way")
        XCTAssertEqual(indicator.state, .transcribing)
        apple.isHeld = false
        try await waitUntil("it hides once the text is pasted") { !indicator.isShowing }
        XCTAssertEqual(paster.pasted, ["Hello there."])
    }

    /// The menu bar shows the error first, as before, then the work under
    /// way once the error has had its time.
    @MainActor
    func testTheMenuBarStillShowsTheErrorOverWorkUnderWay() async throws {
        let apple = appleEngine()
        apple.isHeld = true
        let model = makeModel([apple])
        model.pipeline.errorDisplaySeconds = 0.3
        try await showAnErrorOverADictationInLine(model, apple)

        XCTAssertEqual(MenuBarContent.statusLine(for: model.pipeline.state), "Error: Microphone in use by another app")
        XCTAssertEqual(MenuBarLabel.symbolName(for: model.pipeline.state, exists: { _ in true }), "mic.slash.fill")
        try await waitUntil("the error has had its time") { model.pipeline.state == .transcribing }
        XCTAssertEqual(MenuBarContent.statusLine(for: model.pipeline.state), "Status: Transcribing...")
        apple.isHeld = false
        try await waitUntil("the dictation pastes") { self.paster.pasted == ["Hello there."] }
    }

    // MARK: - The app

    /// Closing the window leaves the app running in the menu bar.
    @MainActor
    func testClosingTheWindowDoesNotQuit() {
        let lifecycle = AppLifecycle()
        XCTAssertFalse(lifecycle.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    /// ⌘Q saves the edit being typed at once: the autosave waits about half
    /// a second after the last keystroke, and the app would be gone by then.
    /// AppKit tells the delegate it is quitting; so does this test.
    @MainActor
    func testQuittingSavesTheEditBeingTyped() throws {
        let model = makeModel([appleEngine()])
        let lifecycle = AppLifecycle(model: model)
        let t = try XCTUnwrap(model.store.add(DictationOutcome(
            date: Date(timeIntervalSince1970: 1_762_900_000), clip: nil, rawText: "Hello there.", text: "Hello there.",
            model: .appleSpeech, transcribeSeconds: 0.2, appName: "TextEdit", status: .pasted)))
        model.library.windowOpened()
        model.library.edit(t, text: "Hello there, Danny.")
        XCTAssertEqual(t.text, "Hello there.", "not saved yet: the autosave is still waiting")

        let delegate: NSApplicationDelegate = lifecycle
        delegate.applicationWillTerminate?(Notification(name: NSApplication.willTerminateNotification))

        XCTAssertEqual(t.text, "Hello there, Danny.")
        XCTAssertTrue(t.isEdited)
    }

    /// Quitting frees the speech models first, then lets the quit go on:
    /// whisper.cpp aborts the exit, and macOS reports a crash, if a model
    /// still holds Metal memory then (the reports of 2026-11-20 and -22).
    @MainActor
    func testQuittingFreesTheModelsBeforeTheQuitGoesOn() async {
        let engine = appleEngine()
        let lifecycle = AppLifecycle(model: makeModel([engine]))
        let wentOn = expectation(description: "the quit goes on")

        lifecycle.quitWhenModelsAreFreed(within: .seconds(5)) { quit in
            XCTAssertTrue(quit)
            XCTAssertEqual(engine.unloads, 1, "freed before the quit goes on")
            wentOn.fulfill()
        }

        await fulfillment(of: [wentOn], timeout: 5)
    }

    /// A model slow to free never holds the quit up past the limit, and the
    /// quit goes on once only, even when the freeing finishes later.
    @MainActor
    func testQuittingGoesOnOnceWhenFreeingTakesTooLong() async throws {
        let engine = appleEngine()
        engine.unloadDelay = 0.5
        let lifecycle = AppLifecycle(model: makeModel([engine]))
        let wentOn = expectation(description: "the quit goes on")
        let started = Date()

        lifecycle.quitWhenModelsAreFreed(within: .milliseconds(100)) { quit in
            XCTAssertTrue(quit)
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.4, "not held up by the slow unload")
            wentOn.fulfill()
        }

        await fulfillment(of: [wentOn], timeout: 2)
        try await Task.sleep(for: .seconds(0.8))
        XCTAssertEqual(engine.unloads, 1, "the slow unload has finished, and the quit went on only once")
    }

    // MARK: - Windows and Paste again (Ruling T19-5)

    /// A real opening of the main window activates the app and opens the
    /// library on the newest transcript (Ruling T18-4).
    @MainActor
    func testARealOpeningActivatesAndSelectsTheNewest() throws {
        let activation = FakeActivation()
        let model = makeModel([appleEngine()])
        let lifecycle = AppLifecycle(model: model, activation: activation.activation)
        _ = try XCTUnwrap(model.store.add(pasteAgainOutcome("Older.", at: 0)))
        let newer = try XCTUnwrap(model.store.add(pasteAgainOutcome("Newer.", at: 60)))

        lifecycle.windowDidOpen(AppModel.mainWindowID)

        XCTAssertEqual(activation.calls, [.regularPolicy, .activate])
        XCTAssertEqual(model.library.selection, newer.id)
    }

    /// Paste again hides every window and shows them again. However SwiftUI
    /// reports that, as closes during the run and opens during or after it,
    /// none of it is a real opening: no policy change, no activation (which
    /// would send the pasted-for Cmd+V to this app), and the library keeps
    /// the transcript pasted and its message. A real close and reopen
    /// afterwards works as ever.
    @MainActor
    func testPasteAgainsReturnNeverActivates() async throws {
        for returnsDuringTheRun in [true, false] {
            let apps = FakeApps()
            apps.frontmostAfterHide = nil
            let activation = FakeActivation()
            let model = makeModel([appleEngine()], apps: apps)
            let lifecycle = AppLifecycle(model: model, activation: activation.activation)
            let ids = [AppModel.mainWindowID, AppModel.welcomeWindowID, AppModel.settingsWindowID]
            let library = model.library
            library.pasteAgainWaitLimit = 0.1
            let older = try XCTUnwrap(model.store.add(pasteAgainOutcome("Older.", at: 0)))
            _ = try XCTUnwrap(model.store.add(pasteAgainOutcome("Newer.", at: 60)))
            for id in ids { lifecycle.windowDidOpen(id) }
            library.selection = older.id
            activation.reset()

            apps.onHide = { activation.isHidden = true; for id in ids { lifecycle.windowDidClose(id) } }
            apps.onUnhide = { activation.isHidden = false; if returnsDuringTheRun { for id in ids { lifecycle.windowDidOpen(id) } } }
            await library.pasteAgain(older)
            if !returnsDuringTheRun { for id in ids { lifecycle.windowDidOpen(id) } }

            XCTAssertEqual(apps.unhides, 1)
            XCTAssertEqual(activation.calls, [], "the return is no opening (during the run: \(returnsDuringTheRun))")
            XCTAssertEqual(library.selection, older.id)
            XCTAssertEqual(library.message(for: older), "Copied — paste with ⌘V")

            // The next appearance is a real one.
            apps.onHide = nil
            apps.onUnhide = nil
            lifecycle.windowDidOpen(AppModel.welcomeWindowID)
            XCTAssertEqual(activation.calls, [.regularPolicy, .activate])
        }
    }

    /// A close during the run while the app is not hidden is Danny closing
    /// the window, not the hide: it is a real close, with its commit and its
    /// return to the menu bar, and the window's next opening is a real one
    /// (policy, activation, newest transcript).
    @MainActor
    func testARealCloseDuringPasteAgainStaysARealClose() async throws {
        let apps = FakeApps()
        apps.frontmostAfterHide = nil
        let activation = FakeActivation()
        let model = makeModel([appleEngine()], apps: apps)
        let lifecycle = AppLifecycle(model: model, activation: activation.activation)
        let library = model.library
        let older = try XCTUnwrap(model.store.add(pasteAgainOutcome("Older.", at: 0)))
        let newer = try XCTUnwrap(model.store.add(pasteAgainOutcome("Newer.", at: 60)))
        lifecycle.windowDidOpen(AppModel.mainWindowID)
        library.selection = older.id
        activation.reset()

        // The hide makes the app hidden; then Danny brings it back and closes main.
        apps.onHide = { activation.isHidden = true }
        apps.onUnhide = { activation.isHidden = false }
        library.pasteAgainWaitLimit = 0.3
        let run = Task { @MainActor in await library.pasteAgain(older) }
        try await waitUntil("the app is hidden") { activation.isHidden }
        activation.isHidden = false
        XCTAssertTrue(library.isPastingAgain, "the close must land during the run, or this test proves nothing")
        lifecycle.windowDidClose(AppModel.mainWindowID)
        await run.value

        try await waitUntil("the app leaves and hides") { activation.calls == [.accessoryPolicy, .hide] }
        XCTAssertFalse(library.isWindowOpen, "the library heard of the close")

        activation.reset()
        lifecycle.windowDidOpen(AppModel.mainWindowID)
        XCTAssertEqual(activation.calls, [.regularPolicy, .activate])
        XCTAssertEqual(library.selection, newer.id)
    }

    /// Close and reopen the main window after a run: both real, and the
    /// reopened library opens on the newest transcript.
    @MainActor
    func testClosingAndReopeningMainAfterPasteAgainSelectsTheNewest() async throws {
        let apps = FakeApps()
        apps.frontmostAfterHide = nil
        let activation = FakeActivation()
        let model = makeModel([appleEngine()], apps: apps)
        let lifecycle = AppLifecycle(model: model, activation: activation.activation)
        let library = model.library
        library.pasteAgainWaitLimit = 0.1
        let older = try XCTUnwrap(model.store.add(pasteAgainOutcome("Older.", at: 0)))
        let newer = try XCTUnwrap(model.store.add(pasteAgainOutcome("Newer.", at: 60)))
        lifecycle.windowDidOpen(AppModel.mainWindowID)
        library.selection = older.id
        apps.onHide = { activation.isHidden = true; lifecycle.windowDidClose(AppModel.mainWindowID) }
        apps.onUnhide = { activation.isHidden = false }
        await library.pasteAgain(older)
        lifecycle.windowDidOpen(AppModel.mainWindowID)
        XCTAssertEqual(library.selection, older.id, "the paired return is ignored")
        activation.reset()

        apps.onHide = nil
        lifecycle.windowDidClose(AppModel.mainWindowID)
        try await waitUntil("the app leaves and hides") { activation.calls == [.accessoryPolicy, .hide] }
        activation.reset()
        lifecycle.windowDidOpen(AppModel.mainWindowID)

        XCTAssertEqual(activation.calls, [.regularPolicy, .activate])
        XCTAssertEqual(library.selection, newer.id)
    }

    /// Closing the last window outside Paste again returns to the menu bar
    /// and hides.
    @MainActor
    func testARealCloseLeavesAndHides() async throws {
        let activation = FakeActivation()
        let model = makeModel([appleEngine()])
        let lifecycle = AppLifecycle(model: model, activation: activation.activation)

        lifecycle.windowDidClose(AppModel.mainWindowID)
        try await waitUntil("the app hides") { activation.calls == [.accessoryPolicy, .hide] }
    }

    // MARK: - Helpers

    @MainActor
    private func pasteAgainOutcome(_ text: String, at offset: TimeInterval) -> DictationOutcome {
        DictationOutcome(date: Date(timeIntervalSince1970: 1_762_900_000 + offset), clip: nil, rawText: text, text: text,
                         model: .appleSpeech, transcribeSeconds: 0.2, appName: "TextEdit", status: .pasted)
    }

    @MainActor
    func testCreatingTheModelRegistersTheFontsOnce() {
        let before = Fonts.registerCalls
        _ = makeModel([appleEngine()])
        XCTAssertEqual(Fonts.registerCalls, before + 1)
    }

    @MainActor
    private func makeModel(_ engines: [FakeEngine], selected: ModelID = .appleSpeech,
                           system: OnboardingSystem = .fake(), indicator: FakeIndicator? = nil,
                           apps: FakeApps? = nil, cleaner: TextCleaner? = nil,
                           miniView: FakeMiniView? = nil) -> AppModel {
        AppModel(service: TranscriptionService(engines: engines, selected: selected),
                 recorder: recorder, paster: paster,
                 store: TranscriptStore(directory: directory, inMemory: true),
                 preferences: preferences, hotkeys: FakeHotkeys(), settingsSystem: FakeSettingsSystem().system,
                 dataDirectory: directory, onboardingSystem: system, indicator: indicator,
                 pasteAgain: (apps ?? FakeApps()).system, cleaner: cleaner, miniView: miniView)
    }

    private func isRecording(_ work: DictationState) -> Bool {
        if case .recording = work { true } else { false }
    }

    /// A dictation in line, held in `apple`, then a press whose recording
    /// cannot start: its error shows over the dictation still under way.
    @MainActor
    private func showAnErrorOverADictationInLine(_ model: AppModel, _ apple: FakeEngine,
                                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        model.hotkeyDidStartPress()
        model.hotkeyDidEndPress()
        try await waitUntil("the dictation is being transcribed", file: file, line: line) {
            apple.calls.contains(.transcribe(.appleSpeech))
        }
        recorder.startFailure = "Microphone in use by another app"
        model.hotkeyDidStartPress()
        model.hotkeyDidEndPress()
        XCTAssertEqual(model.pipeline.state, .error("Microphone in use by another app"), file: file, line: line)
        XCTAssertEqual(model.pipeline.dictationsInFlight, 1, "the dictation is still in line", file: file, line: line)
    }

    /// A key-down as the event tap would be given it, made and never posted;
    /// `tag` is its source data, as `PasteEngine` tags the app's own paste.
    private func keyDown(_ key: Int, flags: CGEventFlags = [], tag: Int64 = 0) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.type = .keyDown
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(key))
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        event.flags = flags
        return event
    }

    /// Whether the tap lets a key-down through untouched: it hands back that
    /// same event, unretained, so this compares it while it is alive.
    private func letsThrough(_ tap: ModifierKeyStrategy, _ event: CGEvent) -> Bool {
        tap.handle(.keyDown, event)?.takeUnretainedValue() === event
    }

    /// Whether `line` strays from the centre anywhere a moment from now.
    private func isRaised(_ line: LevelLine) -> Bool {
        line.points(at: ProcessInfo.processInfo.systemUptime + LevelLine.interval).contains { $0.y != LevelLine.height / 2 }
    }

    private func appleEngine() -> FakeEngine {
        FakeEngine(kind: .appleSpeech, models: [descriptor(.appleSpeech, .ready), descriptor(.appleDictation, .notDownloaded)])
    }

    private func descriptor(_ id: ModelID, _ state: ModelDescriptor.State) -> ModelDescriptor {
        ModelDescriptor(id: id, displayName: id.name, detail: "", state: state)
    }

    /// Apple Speech's row, named as the app names it.
    private func appleSpeechRow(_ state: ModelDescriptor.State) -> ModelDescriptor {
        ModelDescriptor(id: .appleSpeech, displayName: "Apple Speech", detail: "", state: state)
    }

    /// The comparison folder's files, by name.
    private func comparisonFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: comparisonDirectory.path)) ?? []).sorted()
    }

    private struct Timeout: Error {}

    /// Polls every 10 ms until `condition` holds. Fails the test after
    /// `limit` seconds instead of hanging.
    @MainActor
    private func waitUntil(_ what: String, within limit: TimeInterval = 2,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(limit)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Waited \(limit) s for: \(what)", file: file, line: line)
                throw Timeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
