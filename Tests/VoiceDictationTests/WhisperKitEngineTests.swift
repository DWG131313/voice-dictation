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

    /// Only large-v3-turbo is on the speed ladder; the other three keep the
    /// engine's name, as they are listed only for comparing.
    func testModelsHavePlainNames() async {
        let models = await WhisperKitEngine(root: root).models()
        XCTAssertEqual(models.map(\.displayName), ["WhisperKit tiny", "WhisperKit base", "WhisperKit small", "Slowest"])
        XCTAssertEqual(models.map(\.technicalName),
                       ["WhisperKit tiny.en", "WhisperKit base.en", "WhisperKit small.en", "WhisperKit large-v3-turbo"])
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
        try await waitUntil(engine, shows: base, as: .preparing)
        var seen = await states(of: engine)
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

    /// Removing a model's files under a running load makes WhisperKit fetch
    /// the missing tokenizer from the network, so `delete` waits for the load.
    func testDeleteWhilePreparingIsRefused() async throws {
        try fakeDownload(tiny)
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        defer { open.finish() }
        let engine = WhisperKitEngine(root: root) { _ in
            for await _ in gate {}
            return try await Self.emptyPipeline()
        }
        let preparing = Task { try await engine.prepare(tiny) }
        try await waitUntil(engine, shows: tiny, as: .preparing)

        do {
            try await engine.delete(tiny)
            XCTFail("delete should be refused while tiny.en prepares")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .failed("WhisperKit tiny.en is still preparing"))
        }

        for folder in try folders(of: tiny) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "\(folder.path) was removed")
        }
        open.finish()
        try await preparing.value
        let loaded = await engine.loadedModels
        XCTAssertEqual(loaded, [tiny])
    }

    /// `fetch` leaves the tokenizer on disk before a cancel can land, so the
    /// model looks downloaded then; a load must not start under the download,
    /// whose failure cleanup would remove its files.
    func testPrepareWhileDownloadingIsRefused() async throws {
        let calls = Calls()
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        defer { open.finish() }
        let engine = WhisperKitEngine(root: root, loader: { _ in
            calls.add()
            return try await Self.emptyPipeline()
        }, fetcher: { _, _, _ in
            try self.fakeDownload(self.tiny)
            for await _ in gate {}
        })
        let downloading = Task { try await engine.download(tiny) { _ in } }
        try await waitUntil(engine, shows: tiny, as: .downloading(0))

        do {
            try await engine.prepare(tiny)
            XCTFail("prepare should be refused while tiny.en downloads")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .modelNotReady(
                "WhisperKit tiny.en is still downloading. This recording is kept: re-transcribe it from the window when it's ready."))
        }

        XCTAssertEqual(calls.value, 0)
        open.finish()
        try await downloading.value
    }

    /// A load that `unload()` overtakes still runs to its end, and shows as
    /// preparing until then, but its model is not kept.
    func testUnloadDuringALoadDropsIt() async throws {
        try fakeDownload(tiny)
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        defer { open.finish() }
        let engine = WhisperKitEngine(root: root) { _ in
            for await _ in gate {}
            return try await Self.emptyPipeline()
        }
        let preparing = Task { try await engine.prepare(tiny) }
        try await waitUntil(engine, shows: tiny, as: .preparing)

        await engine.unload()
        let during = await states(of: engine)[tiny]
        XCTAssertEqual(during, .preparing)
        open.finish()

        do {
            try await preparing.value
            XCTFail("prepare should fail once unload() has dropped its load")
        } catch {
            XCTAssertEqual(error as? TranscriptionError,
                           .modelNotReady("WhisperKit tiny.en was unloaded before it finished loading"))
        }
        let loaded = await engine.loadedModels
        XCTAssertEqual(loaded, [])
        let after = await states(of: engine)[tiny]
        XCTAssertEqual(after, .ready)
    }

    /// A prepare that comes after `unload()` takes over the load still in
    /// flight instead of starting a second one.
    func testPrepareAfterUnloadJoinsTheLoadInFlight() async throws {
        try fakeDownload(tiny)
        let calls = Calls()
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        defer { open.finish() }
        let engine = WhisperKitEngine(root: root) { _ in
            calls.add()
            for await _ in gate {}
            return try await Self.emptyPipeline()
        }
        let first = Task { try await engine.prepare(tiny) }
        try await waitUntil(engine, shows: tiny, as: .preparing)
        await engine.unload()

        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            open.finish()
        }
        try await engine.prepare(tiny)

        try await first.value
        XCTAssertEqual(calls.value, 1)
        let loaded = await engine.loadedModels
        XCTAssertEqual(loaded, [tiny])
    }

    func testEmptyClipGivesNoTextWithoutLoading() async throws {
        // Nothing is downloaded, so trying to load would throw.
        let text = try await WhisperKitEngine(root: root).transcribe(AudioClip(samples: []), model: tiny, vocabulary: [])

        XCTAssertEqual(text, "")
    }

    /// WhisperKit's chunker drops whatever follows the last split when that
    /// is 1 s or less, by default.
    func testChunksKeepTheLastSecond() async throws {
        // 29.5 s of voice, a 0.4 s pause, then a 0.7 s word: the split falls in the pause.
        let paused = Self.audio([(29.5, true), (0.4, false), (0.7, true)])
        // 60.5 s without a pause: split at 30 s and 60 s.
        let continuous = Self.audio([(60.5, true)])

        for samples in [paused, continuous] {
            let chunks = try await WhisperKitEngine.chunks(of: samples, window: Constants.defaultWindowSamples)
            XCTAssertEqual(chunks.map(\.count).reduce(0, +), samples.count, "chunk sizes: \(chunks.map(\.count))")
        }
    }

    /// A short tail with no voice is left out, so it cannot decode to "you".
    func testChunksDropASilentShortTail() async throws {
        // 29.5 s of voice, then 1.1 s of silence: the split falls 0.2 s into
        // the silence, leaving 0.9 s of it.
        let samples = Self.audio([(29.5, true), (1.1, false)])

        let chunks = try await WhisperKitEngine.chunks(of: samples, window: Constants.defaultWindowSamples)

        XCTAssertEqual(chunks.count, 1, "chunk sizes: \(chunks.map(\.count))")
        let kept = chunks.first?.count ?? 0
        XCTAssertGreaterThanOrEqual(kept, 472_000, "all 29.5 s of voice")
        XCTAssertTrue(samples[kept...].allSatisfy { $0 == 0 }, "dropped audio that was not silent")
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
        for folder in try folders(of: tiny) {
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

    /// The model's folder, the Hub client's records for it, and its tokenizer.
    private func folders(of id: ModelID) throws -> [URL] {
        let model = try WhisperKitEngine.model(id)
        return [WhisperKitEngine.modelFolder(of: model, root: root),
                WhisperKitEngine.downloadRecords(of: model, root: root),
                WhisperKitEngine.tokenizerFolder(of: model, root: root)]
    }

    private func states(of engine: WhisperKitEngine) async -> [ModelID: ModelDescriptor.State] {
        var states: [ModelID: ModelDescriptor.State] = [:]
        for model in await engine.models() {
            // A repeated id fails the test instead of crashing the process.
            if states.updateValue(model.state, forKey: model.id) != nil { XCTFail("\(model.id) is listed twice") }
        }
        return states
    }

    /// Waits at most 2 s for `models()` to show `id` in `state`.
    private func waitUntil(_ engine: WhisperKitEngine, shows id: ModelID, as state: ModelDescriptor.State) async throws {
        let deadline = Date().addingTimeInterval(2)
        while await states(of: engine)[id] != state, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// `parts` in order: a 440 Hz tone at 0.3 for voice, zeros for silence.
    private static func audio(_ parts: [(seconds: Double, voiced: Bool)]) -> [Float] {
        parts.flatMap { part in
            (0..<Int(part.seconds * AudioClip.sampleRate)).map { index in
                part.voiced ? Float(0.3 * sin(2 * Double.pi * 440 * Double(index) / AudioClip.sampleRate)) : 0
            }
        }
    }

    /// Counts calls made from any thread.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
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
