import XCTest
@testable import VoiceDictationLib
@testable import VoiceDictationUI

/// The Welcome window's steps, built from fakes: no permission is asked for,
/// no System Settings pane opens, `com.apple.HIToolbox` is never read and no
/// preference is written.
@MainActor
final class OnboardingModelTests: XCTestCase {
    private var microphone = true
    private var microphoneUndetermined = false
    private var accessibility = true
    private var globeKeyUsage: Int? = 0
    private var models: [ModelDescriptor] = [
        ModelDescriptor(id: .appleSpeech, displayName: "Apple Speech", detail: "", state: .ready),
    ]
    private var selected: ModelID? = .appleSpeech
    private var opened: [URL] = []
    private var requests: [String] = []
    private var refreshes = 0
    private var onRefresh: () -> Void = {}
    private let preferences = PreferencesManager(defaults: MemoryPreferenceStore())
    /// The models Download was asked for, in order. The app's own download
    /// (`AppModel.download`) stands behind it; `AppModelTests` runs that one.
    private var downloads: [ModelID] = []
    /// What the next Download gives back: why it failed, or nil once it
    /// finished or was cancelled.
    private var downloadFailure: String?

    // MARK: - Completeness

    func testCompleteWhenAllDone() {
        let model = makeModel()
        model.recordOutcome(pasted(.pasted))

        XCTAssertEqual(model.steps.map(\.id), [.microphone, .accessibility, .globeKey, .speechModel, .tryIt])
        XCTAssertTrue(model.steps.allSatisfy { $0.state == .done })
        XCTAssertTrue(model.isComplete)
    }

    func testOneStepNeededMeansNotComplete() {
        let model = makeModel()
        model.recordOutcome(pasted(.pasted))
        accessibility = false

        XCTAssertEqual(model.state(of: .accessibility), .needed)
        XCTAssertFalse(model.isComplete)
    }

    func testTheWindowShowsAtLaunchWhileSomethingIsLeftAndOnTheFirstRun() {
        let model = makeModel()
        XCTAssertTrue(model.shouldShowAtLaunch(firstLaunch: false), "the try-it step is not done yet")
        model.recordOutcome(pasted(.pasted))
        XCTAssertFalse(model.shouldShowAtLaunch(firstLaunch: false))
        XCTAssertTrue(model.shouldShowAtLaunch(firstLaunch: true))
        microphone = false
        XCTAssertTrue(model.shouldShowAtLaunch(firstLaunch: false))
    }

    // MARK: - Permissions

    func testMicrophoneAsksOnceThenOpensItsPane() {
        let model = makeModel()
        microphone = false
        microphoneUndetermined = true
        model.open(.microphone)
        XCTAssertEqual(requests, ["microphone"])
        XCTAssertTrue(opened.isEmpty)

        microphoneUndetermined = false
        model.open(.microphone)
        XCTAssertEqual(requests, ["microphone"])
        XCTAssertEqual(opened.map(\.absoluteString),
                       ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"])
    }

    func testAccessibilityListsTheAppThenOpensItsPane() {
        let model = makeModel()
        accessibility = false
        model.open(.accessibility)
        XCTAssertEqual(requests, ["accessibility"])
        XCTAssertEqual(opened.map(\.absoluteString),
                       ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"])
    }

    // MARK: - Globe key

    func testGlobeKeyStepUsesHIToolboxSetting() {
        let model = makeModel()
        for usage in [nil, 0] as [Int?] {
            globeKeyUsage = usage
            model.refresh()
            XCTAssertEqual(model.state(of: .globeKey), .done, "usage \(String(describing: usage))")
        }
        for usage in [1, 2, 3] {
            globeKeyUsage = usage
            model.refresh()
            XCTAssertEqual(model.state(of: .globeKey), .needed, "usage \(usage)")
        }
        XCTAssertEqual(refreshes, 0, "refresh() re-reads permissions, not models")

        model.open(.globeKey)
        XCTAssertEqual(opened.map(\.absoluteString), ["x-apple.systempreferences:com.apple.Keyboard-Settings.extension"])
    }

    /// Ruling P7 (the test Task 14 left to Task 23): the Globe key step
    /// applies only while the hotkey is Globe. With a right-hand key nothing
    /// in Keyboard settings needs changing, so the step is left out, and a
    /// Globe key that still shows emoji keeps nothing from being complete.
    func testGlobeKeyStepAppliesOnlyWhenTheHotkeyIsGlobe() {
        let model = makeModel()
        model.recordOutcome(pasted(.pasted))
        globeKeyUsage = 2
        model.refresh()
        XCTAssertEqual(model.steps.map(\.id), [.microphone, .accessibility, .globeKey, .speechModel, .tryIt])
        XCTAssertFalse(model.isComplete)
        XCTAssertTrue(model.shouldShowAtLaunch(firstLaunch: false))

        for choice in [HotkeyChoice.rightOption, .rightCommand] {
            preferences.hotkey = choice
            XCTAssertEqual(model.steps.map(\.id), [.microphone, .accessibility, .speechModel, .tryIt], "\(choice)")
            XCTAssertTrue(model.isComplete, "\(choice)")
            XCTAssertFalse(model.shouldShowAtLaunch(firstLaunch: false), "\(choice)")
        }

        preferences.hotkey = .globe
        XCTAssertEqual(model.state(of: .globeKey), .needed, "back on Globe, the step applies again")
        XCTAssertFalse(model.isComplete)
    }

    /// The window's words name the hotkey chosen, not 🌐 whatever it is: the
    /// Try it step, the Accessibility step and the line under the title.
    func testTheWordsNameTheChosenHotkey() {
        let model = makeModel()
        accessibility = false
        preferences.hotkey = .rightOption
        XCTAssertEqual(model.step(.tryIt).detail, "Click into any text field, hold Right Option, say a sentence and let go.")
        XCTAssertEqual(model.step(.accessibility).detail,
                       "Needed to watch for the Right Option key and paste. Switch VoiceDictation on in the list.")
        XCTAssertEqual(model.summary, "A few things to set up before you can hold Right Option and talk.")
        preferences.hotkey = .globe
        XCTAssertEqual(model.step(.tryIt).detail, "Click into any text field, hold Globe, say a sentence and let go.")
        XCTAssertEqual(model.step(.accessibility).detail,
                       "Needed to watch for the Globe key and paste. Switch VoiceDictation on in the list.")

        accessibility = true
        model.recordOutcome(pasted(.pasted))
        for (choice, name) in [(HotkeyChoice.globe, "Globe"), (.rightOption, "Right Option"), (.rightCommand, "Right Command")] {
            preferences.hotkey = choice
            XCTAssertEqual(model.summary, "You are all set. Hold \(name) anywhere to dictate.")
        }
    }

    // MARK: - Speech model

    func testSpeechModelStepNeededWhenAssetsMissing() async throws {
        models = [ModelDescriptor(id: .appleSpeech, displayName: "Apple Speech", detail: "", state: .notDownloaded)]
        let model = makeModel()
        XCTAssertEqual(model.state(of: .speechModel), .needed)

        // Apple's files arrive at once; the list then shows the model ready.
        onRefresh = { [self] in
            models = [ModelDescriptor(id: .appleSpeech, displayName: "Apple Speech", detail: "", state: .ready)]
        }
        await model.downloadSelectedModel()

        XCTAssertEqual(downloads, [.appleSpeech])
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(model.state(of: .speechModel), .done)
    }

    /// T14-1 in general: Download fetches the selected model, whichever engine it is.
    func testDownloadFetchesTheSelectedModelOfAnotherEngine() async {
        let tiny = ModelID(engine: .whisperKit, name: "openai_whisper-tiny.en")
        models = [ModelDescriptor(id: .appleSpeech, displayName: "Apple Speech", detail: "", state: .ready),
                  ModelDescriptor(id: tiny, displayName: "Tiny", detail: "", state: .notDownloaded)]
        selected = tiny
        let model = makeModel()
        XCTAssertEqual(model.step(.speechModel).actionTitle, "Download the Tiny model")

        await model.downloadSelectedModel()

        XCTAssertEqual(downloads, [tiny])
    }

    /// The default model since Task 27A. It is fetched only when Danny presses
    /// the step's Download, never by itself. Its progress is the app's
    /// download's (`AppModelTests.testTheWelcomeDownloadIsTheAppsAndItsCancelStopsIt`).
    func testSpeechModelStepDownloadsWhisperCppBase() async throws {
        models = [ModelDescriptor(id: .whisperCppBase, displayName: "Fast", detail: "", state: .notDownloaded)]
        selected = .whisperCppBase
        let model = makeModel()
        XCTAssertEqual(model.state(of: .speechModel), .needed)
        XCTAssertEqual(model.step(.speechModel).actionTitle, "Download the Fast model")
        XCTAssertEqual(model.step(.speechModel).detail, "The Fast model needs its files before it can listen.")
        XCTAssertEqual(downloads, [], "nothing downloads until Download is pressed")

        onRefresh = { [self] in
            models = [ModelDescriptor(id: .whisperCppBase, displayName: "Fast", detail: "", state: .ready)]
        }
        await model.downloadSelectedModel()

        XCTAssertEqual(downloads, [.whisperCppBase], "Apple Speech was not asked")
        XCTAssertEqual(model.state(of: .speechModel), .done)
        XCTAssertEqual(model.step(.speechModel).detail, "The Fast model is ready.")
    }

    /// A failed Download says why on the step, in the words the app gives
    /// (final fix wave, E1), and offers Download again. A cancelled one says
    /// nothing, and the next press clears what an earlier failure said.
    func testAFailedDownloadSaysWhyAndACancelSaysNothing() async {
        models = [ModelDescriptor(id: .appleSpeech, displayName: "Apple Speech", detail: "", state: .notDownloaded)]
        let model = makeModel()

        downloadFailure = "Apple Speech language files could not be installed: No network"
        await model.downloadSelectedModel()
        XCTAssertEqual(model.step(.speechModel).detail,
                       "The download failed: Apple Speech language files could not be installed: No network")
        XCTAssertEqual(model.step(.speechModel).actionTitle, "Download the Apple Speech model")

        downloadFailure = nil
        await model.downloadSelectedModel()
        XCTAssertEqual(model.step(.speechModel).detail, "The Apple Speech model needs its files before it can listen.")
    }

    /// Preparing is the normal state at launch, not a reason to interrupt.
    func testAPreparingModelDoesNotOpenTheWindowAtLaunch() {
        let model = makeModel()
        model.recordOutcome(pasted(.pasted))
        models = [ModelDescriptor(id: .appleSpeech, displayName: "Apple Speech", detail: "", state: .preparing)]
        XCTAssertFalse(model.isComplete)
        XCTAssertFalse(model.shouldShowAtLaunch(firstLaunch: false))
        models = [ModelDescriptor(id: .appleSpeech, displayName: "Apple Speech", detail: "", state: .notDownloaded)]
        XCTAssertTrue(model.shouldShowAtLaunch(firstLaunch: false))
    }

    func testSpeechModelStepFollowsTheSelectedModelNotAppleSpeech() async {
        let tiny = ModelID(engine: .whisperKit, name: "openai_whisper-tiny.en")
        models = [ModelDescriptor(id: .appleSpeech, displayName: "Apple Speech", detail: "", state: .notDownloaded),
                  ModelDescriptor(id: tiny, displayName: "Tiny", detail: "", state: .ready)]
        selected = tiny
        XCTAssertEqual(makeModel().state(of: .speechModel), .done)
    }

    func testSpeechModelStatesMapToSteps() {
        let model = makeModel()
        func step(_ state: ModelDescriptor.State) -> OnboardingModel.Step {
            models = [ModelDescriptor(id: .appleSpeech, displayName: "Apple Speech", detail: "", state: state)]
            return model.step(.speechModel)
        }
        XCTAssertEqual(step(.ready).state, .done)
        XCTAssertEqual(step(.notDownloaded).state, .needed)
        XCTAssertNotNil(step(.notDownloaded).actionTitle)
        XCTAssertEqual(step(.downloading(0.4)).state, .needed)
        XCTAssertEqual(step(.downloading(0.4)).detail, "Downloading… 40%")
        XCTAssertNil(step(.downloading(0.4)).actionTitle)
        XCTAssertEqual(step(.preparing).state, .needed)
        XCTAssertEqual(step(.preparing).detail, "Preparing…")
        XCTAssertEqual(step(.unavailable("Not on this Mac")).state, .unavailable("Not on this Mac"))
    }

    func testSpeechModelStepWaitsForTheListToLoad() {
        models = []
        let step = makeModel().step(.speechModel)
        XCTAssertEqual(step.state, .needed)
        XCTAssertNil(step.actionTitle)
    }

    // MARK: - Try it

    func testTryItStepCompletesOnFirstPastedOutcome() {
        let model = makeModel()
        XCTAssertEqual(model.state(of: .tryIt), .needed)

        model.recordOutcome(pasted(.failed))
        model.recordOutcome(pasted(.copied))
        XCTAssertEqual(model.state(of: .tryIt), .needed)

        model.recordOutcome(pasted(.pasted))
        XCTAssertEqual(model.state(of: .tryIt), .done)
        XCTAssertTrue(preferences.onboardingTriedIt, "kept, so the window does not return at every launch")
        XCTAssertTrue(makeModel().step(.tryIt).state == .done)
    }

    // MARK: - Helpers

    private func makeModel() -> OnboardingModel {
        let system = OnboardingSystem(
            microphoneGranted: { [self] in microphone },
            microphoneUndetermined: { [self] in microphoneUndetermined },
            requestMicrophone: { [self] in requests.append("microphone") },
            accessibilityGranted: { [self] in accessibility },
            requestAccessibility: { [self] in requests.append("accessibility") },
            globeKeyUsageType: { [self] in globeKeyUsage },
            openURL: { [self] in opened.append($0) },
            refreshPermissions: {}
        )
        return OnboardingModel(system: system,
                               download: { [self] id in
                                   downloads.append(id)
                                   return downloadFailure
                               },
                               models: { [self] in models },
                               selected: { [self] in selected },
                               refreshModels: { [self] in refreshes += 1; onRefresh() },
                               preferences: preferences)
    }

    private func pasted(_ status: DictationOutcome.Status) -> DictationOutcome {
        DictationOutcome(date: Date(), clip: nil, rawText: "hi", text: "hi", model: .appleSpeech,
                         transcribeSeconds: 0.1, appName: "TextEdit", status: status)
    }
}
