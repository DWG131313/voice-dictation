import AppKit
import XCTest
@testable import VoiceDictationLib
@testable import VoiceDictationUI

/// The wiring `AppModel` took over from `AppDelegate`, built from fakes: no
/// microphone, no event tap, an in-memory store, preferences in memory and
/// comparison recordings in a temporary folder. `start()` is never called
/// here: it asks for permissions and arms the Globe key.
final class AppModelTests: XCTestCase {
    private let recorder = FakeRecorder()
    private let paster = FakePaster()
    private let preferences = PreferencesManager(defaults: MemoryPreferenceStore())
    private let queue = DispatchQueue(label: "AppModelTests.comparison")
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vd-appmodel-\(UUID().uuidString)", isDirectory: true)
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

    /// Every finished dictation reaches the store (Task 11) and, while the
    /// setting is on, the comparison recordings (Ruling T9-1).
    @MainActor
    func testEveryDictationIsKeptAndRecordedForComparison() async throws {
        preferences.keepComparisonRecordings = true
        let model = makeModel([appleEngine()])

        model.hotkeyDidStartPress()
        model.hotkeyDidEndPress()

        try await waitUntil("the transcript is kept") { !model.store.search("", scope: .all).isEmpty }
        XCTAssertEqual(paster.pasted, ["Hello there."])
        let transcript = try XCTUnwrap(model.store.search("", scope: .all).first)
        XCTAssertEqual(transcript.text, "Hello there.")
        XCTAssertEqual(transcript.status, .pasted)
        try await waitUntil("the recording is kept for comparison") { self.comparisonFiles().count == 2 }
        let text = try XCTUnwrap(comparisonFiles().first { $0.hasSuffix(".txt") })
        XCTAssertEqual(try String(contentsOf: comparisonDirectory.appendingPathComponent(text), encoding: .utf8),
                       "Hello there.")
        // The first pasted dictation completes the Welcome window's last step.
        XCTAssertEqual(model.onboarding.state(of: .tryIt), .done)
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

    /// Ruling T9-2: a dictation whose text came back empty pastes nothing and
    /// is no transcript, but its clip is kept for comparison, with empty text.
    @MainActor
    func testAnEmptyTextIsKeptForComparisonOnly() async throws {
        preferences.keepComparisonRecordings = true
        let apple = appleEngine()
        apple.result = ""
        let model = makeModel([apple])

        model.hotkeyDidStartPress()
        model.hotkeyDidEndPress()

        try await waitUntil("the recording is kept for comparison") { self.comparisonFiles().count == 2 }
        let text = try XCTUnwrap(comparisonFiles().first { $0.hasSuffix(".txt") })
        XCTAssertEqual(try String(contentsOf: comparisonDirectory.appendingPathComponent(text), encoding: .utf8), "")
        XCTAssertTrue(model.store.search("", scope: .all).isEmpty)
        XCTAssertTrue(paster.pasted.isEmpty)
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
        recorder.onLevel?(0.5)
        try await waitUntil("the line rises") { self.isRaised(indicator.line) }
        let first = indicator.state
        model.hotkeyDidEndPress()
        try await waitUntil("the first dictation is pasted") { self.paster.pasted.count == 1 }

        model.hotkeyDidStartPress()
        try await waitUntil("the second recording shows") { indicator.showsListening && indicator.state != first }
        XCTAssertFalse(isRaised(indicator.line))
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
                           apps: FakeApps? = nil) -> AppModel {
        AppModel(service: TranscriptionService(engines: engines, selected: selected),
                 recorder: recorder, paster: paster,
                 store: TranscriptStore(directory: directory, inMemory: true),
                 preferences: preferences,
                 comparison: ComparisonRecordings(directory: comparisonDirectory, preferences: preferences, queue: queue),
                 dataDirectory: directory, onboardingSystem: system, indicator: indicator,
                 pasteAgain: (apps ?? FakeApps()).system)
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

    /// The comparison folder's files, once every write handed over so far is done.
    private func comparisonFiles() -> [String] {
        queue.sync {}
        return (try? FileManager.default.contentsOfDirectory(atPath: comparisonDirectory.path)) ?? []
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
