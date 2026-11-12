import WhisperKit
import XCTest
@testable import VoiceDictationLib

final class WhisperKitEngineTests: XCTestCase {
    private let tiny = ModelID(engine: .whisperKit, name: "tiny.en")
    private let base = ModelID(engine: .whisperKit, name: "base.en")
    /// A fresh folder per test. The tests named …WhenTinyIsPresent use the
    /// app's own models instead.
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperkit-engine-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testOffersFourModels() async {
        let models = await WhisperKitEngine(root: root).models()

        XCTAssertEqual(models.map(\.id), ["tiny.en", "base.en", "small.en", "large-v3-turbo"].map {
            ModelID(engine: .whisperKit, name: $0)
        })
        for model in models {
            XCTAssertTrue([.notDownloaded, .ready].contains(model.state), "\(model.id.name) is \(model.state)")
        }
    }

    func testTranscribeWithoutDownloadThrowsModelNotReady() async {
        let clip = AudioClip(samples: [Float](repeating: 0.1, count: 16_000))
        do {
            _ = try await WhisperKitEngine(root: root).transcribe(clip, model: tiny, vocabulary: [])
            XCTFail("transcribe should throw")
        } catch {
            guard case .modelNotReady? = error as? TranscriptionError else { return XCTFail("threw \(error)") }
        }
    }

    func testTranscribesSampleWhenTinyIsPresent() async throws {
        let appRoot = try Self.appRoot()
        let engine = try await engineWithTiny(at: appRoot)
        let documentsHub = try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appending(path: "huggingface")
        let hubExistedBefore = FileManager.default.fileExists(atPath: documentsHub.path)

        try await engine.prepare(tiny)
        // A vocabulary takes the prompt path; none of its words are spoken.
        let text = try await engine.transcribe(try sample(), model: tiny, vocabulary: ["Prism", "WhisperKit"])

        XCTAssertTrue(text.lowercased().contains("quick brown fox"), "tiny.en heard: \(text)")
        XCTAssertTrue(Self.files(under: appRoot).contains { $0.lastPathComponent == "tokenizer.json" })
        if !hubExistedBefore {
            XCTAssertFalse(FileManager.default.fileExists(atPath: documentsHub.path), "something wrote ~/Documents/huggingface")
        }
    }

    /// WhisperKit's default `windowClipTime` would skip a clip of 1 s or less,
    /// so a short dictation such as "Yes." would come back empty.
    func testShortClipIsTranscribedWhenTinyIsPresent() async throws {
        let engine = try await engineWithTiny(at: try Self.appRoot())
        // The first 0.8 s of the sample: "The quick brown".
        let short = AudioClip(samples: Array(try sample().samples.prefix(12_800)))

        let text = try await engine.transcribe(short, model: tiny, vocabulary: [])

        XCTAssertTrue(text.lowercased().contains("quick"), "tiny.en heard: \(text)")
    }

    func testCancellationStopsPromptlyWhenTinyIsPresent() async throws {
        let engine = try await engineWithTiny(at: try Self.appRoot())
        let speech = try sample().samples
        // Two minutes of speech in four windows: far more than tiny.en gets through in 100 ms.
        let long = AudioClip(samples: Array(Array(repeating: speech, count: 45).joined()))
        try await engine.prepare(tiny)

        let task = Task { try await engine.transcribe(long, model: tiny, vocabulary: []) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        await assertCancelled(task, within: 1)
    }

    func testLoadConfigStaysLocal() {
        let config = WhisperKitEngine.loadConfig(for: tiny, root: root)

        XCTAssertEqual(config.model, "openai_whisper-tiny.en")
        XCTAssertTrue(isInsideRoot(config.downloadBase?.path), "downloadBase: \(String(describing: config.downloadBase))")
        XCTAssertTrue(isInsideRoot(config.tokenizerFolder?.path), "tokenizerFolder: \(String(describing: config.tokenizerFolder))")
        XCTAssertTrue(isInsideRoot(config.modelFolder), "modelFolder: \(String(describing: config.modelFolder))")
        XCTAssertFalse(config.download)
        // The folder WhisperKit's own downloader fills when given `root`.
        let repo = HubApiWrapper(downloadBase: root).localRepoLocation(HubApiWrapper.Repo(id: "argmaxinc/whisperkit-coreml"))
        XCTAssertEqual(config.modelFolder, repo.appending(path: "openai_whisper-tiny.en").path)
    }

    /// Ruling T7-3: a second model joins the first instead of replacing it.
    func testPreparingSecondModelKeepsFirstLoaded() async throws {
        try fakeDownload(tiny)
        try fakeDownload(base)
        // base.en's load waits until the gate opens, so it can be seen preparing.
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        defer { open.finish() }
        let engine = WhisperKitEngine(root: root) { config in
            if config.model == "openai_whisper-base.en" { for await _ in gate {} }
            return try await Self.emptyPipeline()
        }
        try await engine.prepare(tiny)

        let second = Task { try await engine.prepare(base) }
        var seen = await states(of: engine)
        let deadline = Date().addingTimeInterval(2)
        while seen[base] != .preparing, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            seen = await states(of: engine)
        }
        XCTAssertEqual(seen[tiny], .ready)
        XCTAssertEqual(seen[base], .preparing)

        open.finish()
        try await second.value
        seen = await states(of: engine)
        XCTAssertEqual(seen[tiny], .ready)
        XCTAssertEqual(seen[base], .ready)
        let loaded = await engine.loadedModels
        XCTAssertEqual(loaded, [tiny, base])

        await engine.unload()
        let afterUnload = await engine.loadedModels
        XCTAssertEqual(afterUnload, [])
    }

    /// A cancelled transcription stops waiting for its model at once; the
    /// load itself carries on for the next caller.
    func testCancelWhileLoadingStopsPromptly() async throws {
        try fakeDownload(tiny)
        let engine = WhisperKitEngine(root: root) { _ in
            try await Task.sleep(nanoseconds: 500_000_000)
            return try await Self.emptyPipeline()
        }

        let task = Task { try await engine.transcribe(AudioClip(samples: [0.1]), model: tiny, vocabulary: []) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        await assertCancelled(task, within: 0.2)
        try await engine.prepare(tiny)
        let loaded = await engine.loadedModels
        XCTAssertEqual(loaded, [tiny])
    }

    func testDeleteUnloadsAndRemovesFiles() async throws {
        try fakeDownload(tiny)
        let engine = WhisperKitEngine(root: root) { _ in try await Self.emptyPipeline() }
        try await engine.prepare(tiny)
        let before = await engine.models().first { $0.id == tiny }
        XCTAssertEqual(before?.state, .ready)
        XCTAssertGreaterThanOrEqual(before?.bytesOnDisk ?? 0, 3_000, "three 1,000-byte model files")

        try await engine.delete(tiny)

        let loaded = await engine.loadedModels
        XCTAssertEqual(loaded, [])
        let after = await engine.models().first { $0.id == tiny }
        XCTAssertEqual(after?.state, .notDownloaded)
        XCTAssertNil(after?.bytesOnDisk)
        let model = try WhisperKitEngine.model(tiny)
        for folder in [WhisperKitEngine.modelFolder(of: model, root: root),
                       WhisperKitEngine.downloadRecords(of: model, root: root),
                       WhisperKitEngine.tokenizerFolder(of: model, root: root)] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "\(folder.path) is still there")
        }
    }

    // MARK: - Helpers

    /// Where the app keeps its WhisperKit models (Ruling T7-2).
    private static func appRoot() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appending(path: "VoiceDictation/whisperkit", directoryHint: .isDirectory)
    }

    /// An engine on the app's own models; skips unless tiny.en is there.
    private func engineWithTiny(at appRoot: URL) async throws -> WhisperKitEngine {
        let engine = WhisperKitEngine(root: appRoot)
        guard await engine.models().first(where: { $0.id == tiny })?.state == .ready else {
            throw XCTSkip("tiny.en is not downloaded to \(appRoot.path)")
        }
        return engine
    }

    /// A pipeline with nothing loaded, made without model files or network.
    private static func emptyPipeline() async throws -> WhisperKit {
        try await WhisperKit(WhisperKitConfig(verbose: false, load: false, download: false))
    }

    /// Lays out what `download` leaves on disk, with empty models, so the
    /// engine counts the model as downloaded.
    private func fakeDownload(_ id: ModelID) throws {
        let model = try WhisperKitEngine.model(id)
        let manager = FileManager.default
        let folder = WhisperKitEngine.modelFolder(of: model, root: root)
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let bundle = folder.appending(path: "\(name).mlmodelc")
            try manager.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data(count: 1_000).write(to: bundle.appending(path: "model.mil"))
        }
        let tokenizer = WhisperKitEngine.tokenizerFolder(of: model, root: root)
        try manager.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        for name in ["tokenizer.json", "tokenizer_config.json"] {
            try Data("{}".utf8).write(to: tokenizer.appending(path: name))
        }
        let records = WhisperKitEngine.downloadRecords(of: model, root: root)
        try manager.createDirectory(at: records, withIntermediateDirectories: true)
        try Data().write(to: records.appending(path: "config.json.metadata"))
    }

    private func states(of engine: WhisperKitEngine) async -> [ModelID: ModelDescriptor.State] {
        Dictionary(uniqueKeysWithValues: await engine.models().map { ($0.id, $0.state) })
    }

    private func isInsideRoot(_ path: String?) -> Bool {
        guard let path else { return false }
        return path == root.path || path.hasPrefix(root.path + "/")
    }

    /// Every file and folder under `folder`.
    private static func files(under folder: URL) -> [URL] {
        (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
    }

    /// Waits at most `limit` seconds for `task` and asserts it threw
    /// `CancellationError`. A hang fails the test instead of blocking the suite.
    private func assertCancelled(_ task: Task<String, Error>, within limit: TimeInterval,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        let ended = XCTestExpectation(description: "transcribe ended")
        Task {
            _ = await task.result
            ended.fulfill()
        }
        guard await XCTWaiter().fulfillment(of: [ended], timeout: limit) == .completed else {
            return XCTFail("transcribe was still running \(limit) s after the cancel", file: file, line: line)
        }
        switch await task.result {
        case .success(let text):
            XCTFail("finished instead of stopping: \(text.prefix(40))", file: file, line: line)
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "threw \(error)", file: file, line: line)
        }
    }

    private func sample() throws -> AudioClip {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "wav", subdirectory: "Resources"))
        return try AudioClip(contentsOf: url)
    }
}
