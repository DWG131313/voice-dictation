import XCTest
@testable import VoiceDictationLib
@testable import VoiceDictationUI

/// The Models section's operations on `AppModel`, against fake engines
/// behind a real `TranscriptionService`. Nothing is downloaded.
final class ModelsModelTests: XCTestCase {
    private let recorder = FakeRecorder()
    private let paster = FakePaster()
    private let preferences = PreferencesManager(defaults: MemoryPreferenceStore())
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vd-models-\(UUID().uuidString)", isDirectory: true)
    private let tiny = ModelID(engine: .whisperKit, name: "openai_whisper-tiny.en")
    private let base = ModelID(engine: .whisperKit, name: "openai_whisper-base.en")

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @MainActor
    func testUseSelectsAndPersists() async {
        let model = makeModel(selected: .appleSpeech)
        await model.refreshModels()

        await model.use(descriptor(tiny, .ready))

        XCTAssertEqual(preferences.selectedModelID, tiny)
        XCTAssertEqual(model.selectedModel, tiny)
        let inUse = await model.service.selected
        XCTAssertEqual(inUse, tiny)
    }

    @MainActor
    func testCannotDeleteSelected() async {
        let model = makeModel(selected: tiny)
        await model.refreshModels()

        await model.deleteModel(tiny)

        XCTAssertEqual(model.modelMessages[tiny], "The model used for dictation cannot be deleted")
        XCTAssertEqual(model.selectedModel, tiny)
    }

    @MainActor
    func testDeletingAnotherModelClearsOldMessage() async {
        let model = makeModel(selected: .appleSpeech)
        await model.refreshModels()

        await model.deleteModel(.appleSpeech)
        XCTAssertNotNil(model.modelMessages[.appleSpeech])
        await model.deleteModel(base)

        XCTAssertNil(model.modelMessages[base])
    }

    @MainActor
    func testDownloadProgressUpdatesDescriptor() async throws {
        let gate = Gate()
        whisperKit.onDownload = { _, progress in
            progress(0.42)
            await gate.wait()
        }
        let model = makeModel(selected: .appleSpeech)
        await model.refreshModels()

        let download = Task { await model.download(base) }

        try await waitUntil("progress shows") { model.models.first { $0.id == self.base }?.state == .downloading(0.42) }
        await gate.open()
        _ = await download.value
        XCTAssertNil(model.downloadProgress[base])
    }

    @MainActor
    func testCancelDownloadLeavesNotDownloaded() async throws {
        whisperKit.onDownload = { _, progress in
            progress(0.3)
            try await Task.sleep(for: .seconds(60))
        }
        let model = makeModel(selected: .appleSpeech)
        await model.refreshModels()
        let download = Task { await model.download(base) }
        try await waitUntil("download under way") { model.models.first { $0.id == self.base }?.state == .downloading(0.3) }

        model.cancelDownload(base)
        let finished = await download.value

        XCTAssertFalse(finished)
        XCTAssertEqual(model.models.first { $0.id == base }?.state, .notDownloaded)
        XCTAssertNil(model.modelMessages[base], "a cancel is not an error")
        XCTAssertEqual(model.selectedModel, .appleSpeech)
        XCTAssertEqual(preferences.selectedModelID, .appleSpeech, "the saved choice is untouched")
    }

    @MainActor
    func testChangingModelDuringDownloadDoesNotSwitchUntilUseIsPressed() async throws {
        let gate = Gate()
        whisperKit.onDownload = { [whisperKit] id, progress in
            progress(0.5)
            await gate.wait()
            whisperKit.modelList = [ModelDescriptor(id: id, displayName: id.name, detail: "", state: .ready)]
            progress(1)
        }
        whisperKit.modelList = [descriptor(base, .notDownloaded)]
        let model = makeModel(selected: .appleSpeech)
        await model.refreshModels()
        let download = Task { await model.download(base) }
        try await waitUntil("download under way") { model.downloadProgress[base] == 0.5 }

        await gate.open()
        let finished = await download.value

        XCTAssertTrue(finished)
        XCTAssertEqual(model.selectedModel, .appleSpeech, "downloading never switches")
        XCTAssertEqual(preferences.selectedModelID, .appleSpeech)
        XCTAssertEqual(model.models.first { $0.id == base }?.state, .ready)

        await model.use(descriptor(base, .ready))
        XCTAssertEqual(model.selectedModel, base)
        XCTAssertEqual(preferences.selectedModelID, base)
    }

    @MainActor
    func testAFailedDownloadIsShownOnTheRow() async {
        whisperKit.onDownload = { _, _ in throw TranscriptionError.failed("No network") }
        let model = makeModel(selected: .appleSpeech)
        await model.refreshModels()

        let finished = await model.download(base)

        XCTAssertFalse(finished)
        XCTAssertEqual(model.modelMessages[base], "No network")
        XCTAssertNil(model.downloadProgress[base])
    }

    /// Ruling T20-1: the menu bar's choice downloads, then selects, through
    /// the same operations, so the Models section sees its progress.
    @MainActor
    func testChoosingDownloadsThroughTheSharedPath() async throws {
        let gate = Gate()
        whisperKit.onDownload = { [whisperKit] id, progress in
            progress(0.25)
            await gate.wait()
            whisperKit.modelList = [ModelDescriptor(id: id, displayName: id.name, detail: "", state: .ready)]
        }
        whisperKit.modelList = [descriptor(base, .notDownloaded)]
        let model = makeModel(selected: .appleSpeech)
        await model.refreshModels()

        let choice = Task { await model.choose(descriptor(base, .notDownloaded)) }
        try await waitUntil("progress shows") { model.downloadProgress[base] == 0.25 }
        XCTAssertEqual(model.selectedModel, .appleSpeech)
        await gate.open()
        await choice.value

        XCTAssertEqual(model.selectedModel, base)
        XCTAssertEqual(preferences.selectedModelID, base)
    }

    @MainActor
    func testACancelledChoiceSelectsNothing() async throws {
        whisperKit.onDownload = { _, progress in
            progress(0.1)
            try await Task.sleep(for: .seconds(60))
        }
        let model = makeModel(selected: .appleSpeech)
        await model.refreshModels()
        let choice = Task { await model.choose(descriptor(base, .notDownloaded)) }
        try await waitUntil("download under way") { model.downloadProgress[base] == 0.1 }

        model.cancelDownload(base)
        await choice.value

        XCTAssertEqual(model.selectedModel, .appleSpeech)
        XCTAssertEqual(preferences.selectedModelID, .appleSpeech)
    }

    // MARK: - Order

    func testSectionsKeepApplesFirstThenWhisperKitThenThePreviousEngine() {
        let all = [descriptor(.appleSpeech, .ready), descriptor(base, .ready),
                   descriptor(ModelID(engine: .whisperCLI, name: "base.en"), .ready),
                   descriptor(.appleDictation, .ready), descriptor(tiny, .ready)]
        let sections = ModelsView.sections(all)
        XCTAssertEqual(sections.map(\.engine), [.appleSpeech, .whisperKit, .whisperCLI])
        XCTAssertEqual(sections[0].models.map(\.id), [.appleSpeech, .appleDictation])
        XCTAssertEqual(sections[1].models.map(\.id), [base, tiny], "the engine's order is kept: it lists smallest first")
        XCTAssertEqual(sections[2].title, "Previous engine")
    }

    func testButtonsFitTheState() {
        let selected: ModelID = .appleSpeech
        func actions(_ id: ModelID, _ state: ModelDescriptor.State) -> [ModelsView.Action] {
            ModelsView.actions(for: descriptor(id, state), selected: selected)
        }
        XCTAssertEqual(actions(.appleSpeech, .ready), [.inUse])
        XCTAssertEqual(actions(.appleDictation, .ready), [.use])
        XCTAssertEqual(actions(.appleDictation, .notDownloaded), [.download])
        XCTAssertEqual(actions(tiny, .ready), [.use, .delete])
        XCTAssertEqual(actions(tiny, .downloading(0.2)), [.cancel])
        XCTAssertEqual(actions(tiny, .preparing), [])
        XCTAssertEqual(actions(tiny, .unavailable("x")), [])
        XCTAssertEqual(actions(tiny, .notDownloaded), [.download])
        let cli = ModelID(engine: .whisperCLI, name: "base.en")
        XCTAssertEqual(actions(cli, .unavailable("Previous engine: model not downloaded")), [])
    }

    func testStateWords() {
        XCTAssertEqual(ModelsView.stateWord(.ready), "Ready")
        XCTAssertEqual(ModelsView.stateWord(.notDownloaded), "Not downloaded")
        XCTAssertEqual(ModelsView.stateWord(.downloading(0.424)), "Downloading 42%")
        XCTAssertEqual(ModelsView.stateWord(.preparing), "Preparing")
        XCTAssertEqual(ModelsView.stateWord(.unavailable("No room")), "Unavailable: No room")
    }

    // MARK: - Helpers

    private let apple = FakeEngine(kind: .appleSpeech)
    private let whisperKit = FakeEngine(kind: .whisperKit)

    @MainActor
    private func makeModel(selected: ModelID) -> AppModel {
        apple.modelList = [descriptor(.appleSpeech, .ready), descriptor(.appleDictation, .notDownloaded)]
        if whisperKit.modelList.isEmpty {
            whisperKit.modelList = [descriptor(tiny, .ready), descriptor(base, .notDownloaded)]
        }
        return AppModel(service: TranscriptionService(engines: [apple, whisperKit], selected: selected),
                        recorder: recorder, paster: paster,
                        store: TranscriptStore(directory: directory, inMemory: true),
                        preferences: preferences,
                        comparison: ComparisonRecordings(directory: directory.appendingPathComponent("c"), preferences: preferences,
                                                         queue: DispatchQueue(label: "ModelsModelTests")),
                        dataDirectory: directory, onboardingSystem: .fake(), indicator: nil,
                        pasteAgain: FakeApps().system)
    }

    private func descriptor(_ id: ModelID, _ state: ModelDescriptor.State) -> ModelDescriptor {
        ModelDescriptor(id: id, displayName: id.name, detail: "", state: state)
    }

    /// Holds a fake download until the test lets it go.
    private actor Gate {
        private var isOpen = false
        func open() { isOpen = true }
        func wait() async {
            while !isOpen { try? await Task.sleep(for: .milliseconds(2)) }
        }
    }

    private struct Timeout: Error {}

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
