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

    // MARK: - Fix round 1

    /// The menu bar's choice shows the preparing state while it downloads.
    @MainActor
    func testChoosingShowsThePreparingStateWhileDownloading() async throws {
        let gate = Gate()
        whisperKit.onDownload = { _, progress in progress(0.2); await gate.wait() }
        let model = makeModel(selected: .appleSpeech)
        await model.refreshModels()

        let choice = Task { await model.choose(descriptor(base, .notDownloaded)) }
        try await waitUntil("preparing shows") { model.downloadProgress[base] == 0.2 }

        XCTAssertEqual(model.pipeline.state, .preparingModel(base.name))
        await gate.open()
        await choice.value
        XCTAssertNotEqual(model.pipeline.state, .preparingModel(base.name))
    }

    /// A failed menu bar download is shown by the pipeline, window open or not.
    @MainActor
    func testAFailedChoiceIsShownByThePipeline() async {
        whisperKit.onDownload = { _, _ in throw TranscriptionError.failed("No network") }
        let model = makeModel(selected: .appleSpeech)
        await model.refreshModels()

        await model.choose(descriptor(base, .notDownloaded))

        XCTAssertEqual(model.pipeline.state, .error("No network"))
        XCTAssertEqual(model.selectedModel, .appleSpeech)
    }

    @MainActor
    func testACancelledChoiceShowsNoError() async throws {
        whisperKit.onDownload = { _, progress in progress(0.1); try await Task.sleep(for: .seconds(60)) }
        let model = makeModel(selected: .appleSpeech)
        await model.refreshModels()
        let choice = Task { await model.choose(descriptor(base, .notDownloaded)) }
        try await waitUntil("download under way") { model.downloadProgress[base] == 0.1 }

        model.cancelDownload(base)
        await choice.value

        XCTAssertEqual(model.pipeline.state, .idle)
    }

    /// Choosing a model whose download is already under way joins it.
    @MainActor
    func testChoosingAModelAlreadyDownloadingJoinsTheDownload() async throws {
        let gate = Gate()
        whisperKit.onDownload = { [whisperKit] id, progress in
            progress(0.5)
            await gate.wait()
            whisperKit.modelList = [ModelDescriptor(id: id, displayName: id.name, detail: "", state: .ready)]
        }
        let model = makeModel(selected: .appleSpeech)
        await model.refreshModels()
        let download = Task { await model.download(base) }
        try await waitUntil("download under way") { model.downloadProgress[base] == 0.5 }
        let overlaid = try XCTUnwrap(model.models.first { $0.id == base })
        XCTAssertEqual(overlaid.state, .downloading(0.5))

        let choice = Task { await model.choose(overlaid) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.selectedModel, .appleSpeech, "waits for the download")
        await gate.open()
        await choice.value
        _ = await download.value

        XCTAssertEqual(model.selectedModel, base)
        XCTAssertEqual(whisperKit.calls.filter { $0 == .download(base) }.count, 1)
    }

    @MainActor
    func testASecondDownloadCallJoinsTheFirst() async throws {
        let gate = Gate()
        whisperKit.onDownload = { _, progress in progress(0.5); await gate.wait() }
        let model = makeModel(selected: .appleSpeech)
        await model.refreshModels()

        let first = Task { await model.download(base) }
        try await waitUntil("download under way") { model.downloadProgress[base] == 0.5 }
        let second = Task { await model.download(base) }
        try await Task.sleep(for: .milliseconds(30))
        await gate.open()
        let results = [await first.value, await second.value]

        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(whisperKit.calls.filter { $0 == .download(base) }.count, 1)
    }

    /// A note about a row goes when that model's state changes.
    @MainActor
    func testARowMessageGoesWhenTheModelsStateChanges() async {
        let model = makeModel(selected: tiny)
        await model.refreshModels()
        await model.deleteModel(tiny)
        XCTAssertNotNil(model.modelMessages[tiny])

        await model.refreshModels()
        XCTAssertNotNil(model.modelMessages[tiny], "still the same state")
        whisperKit.modelList = [descriptor(tiny, .notDownloaded), descriptor(base, .notDownloaded)]
        await model.refreshModels()

        XCTAssertNil(model.modelMessages[tiny])
    }

    func testCancelOnlyOffersWhatThisAppCanCancel() {
        let row = descriptor(tiny, .downloading(0.2))
        XCTAssertEqual(ModelsView.actions(for: row, selected: .appleSpeech, cancellable: true), [.cancel])
        XCTAssertEqual(ModelsView.actions(for: row, selected: .appleSpeech, cancellable: false), [])
    }

    // MARK: - Order

    /// whisper.cpp, the default, comes first; no group has a heading.
    func testSectionsPutWhisperCppFirst() {
        let cppTiny = ModelID(engine: .whisperCpp, name: "tiny.en")
        let all = [descriptor(.appleSpeech, .ready), descriptor(base, .ready),
                   descriptor(cppTiny, .notDownloaded), descriptor(.whisperCppBase, .ready),
                   descriptor(.appleDictation, .ready), descriptor(tiny, .ready)]
        let sections = ModelsView.sections(all)
        XCTAssertEqual(sections.map(\.engine), [.whisperCpp, .appleSpeech, .whisperKit])
        guard sections.count == 3 else { return }
        XCTAssertEqual(sections[0].models.map(\.id), [cppTiny, .whisperCppBase], "the engine's order is kept")
        XCTAssertEqual(sections[1].models.map(\.id), [.appleSpeech, .appleDictation])
        XCTAssertEqual(sections[2].models.map(\.id), [base, tiny], "the engine's order is kept: it lists smallest first")
    }

    // MARK: - The model in use keeps its file (Ruling T27-4)

    /// whisper-cli read the same `ggml-base.en.bin` as whisper.cpp base.en,
    /// so in Task 27 a saved whisper-cli choice left that file deletable from
    /// the Models section. That choice now reads as whisper.cpp base.en, the
    /// model in use: no Delete is offered for it, and the service refuses it.
    @MainActor
    func testTheWhisperCppModelInUseCannotBeDeleted() async throws {
        let saved = MemoryPreferenceStore()
        saved.set("whisperCLI/base.en", forKey: "selectedModelID")
        let preferences = PreferencesManager(defaults: saved)
        let models = directory.appendingPathComponent("models", isDirectory: true)
        let file = models.appendingPathComponent("ggml-base.en.bin")
        try Self.makeSparseFile(file, bytes: 147_964_211)
        let model = AppModel(service: TranscriptionService(engines: [WhisperCppEngine(directory: models)],
                                                           selected: preferences.selectedModelID),
                             recorder: recorder, paster: paster,
                             store: TranscriptStore(directory: directory, inMemory: true),
                             preferences: preferences, hotkeys: FakeHotkeys(), settingsSystem: FakeSettingsSystem().system,
                             dataDirectory: directory, onboardingSystem: .fake(), indicator: nil,
                             pasteAgain: FakeApps().system)
        await model.refreshModels()

        XCTAssertEqual(model.selectedModel, .whisperCppBase)
        let row = try XCTUnwrap(model.models.first { $0.id == .whisperCppBase })
        XCTAssertEqual(row.state, .ready)
        XCTAssertEqual(ModelsView.actions(for: row, selected: model.selectedModel, cancellable: false), [.inUse])

        await model.deleteModel(.whisperCppBase)

        XCTAssertEqual(model.modelMessages[.whisperCppBase], "The model used for dictation cannot be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the model in use lost its file")
        XCTAssertEqual(model.models.first { $0.id == .whisperCppBase }?.state, .ready)
    }

    func testButtonsFitTheState() {
        let selected: ModelID = .appleSpeech
        func actions(_ id: ModelID, _ state: ModelDescriptor.State) -> [ModelsView.Action] {
            ModelsView.actions(for: descriptor(id, state), selected: selected, cancellable: true)
        }
        XCTAssertEqual(actions(.appleSpeech, .ready), [.inUse])
        XCTAssertEqual(actions(.appleDictation, .ready), [.use])
        XCTAssertEqual(actions(.appleDictation, .notDownloaded), [.download])
        XCTAssertEqual(actions(tiny, .ready), [.use, .delete])
        XCTAssertEqual(actions(tiny, .downloading(0.2)), [.cancel])
        XCTAssertEqual(actions(tiny, .preparing), [])
        XCTAssertEqual(actions(tiny, .unavailable("x")), [])
        XCTAssertEqual(actions(tiny, .notDownloaded), [.download])
        // A whisper.cpp model not in use can be deleted, and downloaded again.
        XCTAssertEqual(actions(.whisperCppBase, .ready), [.use, .delete])
        XCTAssertEqual(actions(.whisperCppBase, .notDownloaded), [.download])
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

    /// The model in use is the saved choice, as when the app starts; with
    /// nothing saved the choice would read as the default, whisper.cpp base.en.
    @MainActor
    private func makeModel(selected: ModelID) -> AppModel {
        preferences.selectedModelID = selected
        apple.modelList = [descriptor(.appleSpeech, .ready), descriptor(.appleDictation, .notDownloaded)]
        if whisperKit.modelList.isEmpty {
            whisperKit.modelList = [descriptor(tiny, .ready), descriptor(base, .notDownloaded)]
        }
        return AppModel(service: TranscriptionService(engines: [apple, whisperKit], selected: selected),
                        recorder: recorder, paster: paster,
                        store: TranscriptStore(directory: directory, inMemory: true),
                        preferences: preferences, hotkeys: FakeHotkeys(), settingsSystem: FakeSettingsSystem().system,
                        dataDirectory: directory, onboardingSystem: .fake(), indicator: nil,
                        pasteAgain: FakeApps().system)
    }

    private func descriptor(_ id: ModelID, _ state: ModelDescriptor.State) -> ModelDescriptor {
        ModelDescriptor(id: id, displayName: id.name, detail: "", state: state)
    }

    /// A file of `bytes` bytes, made sparse, so nothing is written.
    private static func makeSparseFile(_ url: URL, bytes: UInt64) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: bytes)
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
