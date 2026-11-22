import whisper
import XCTest
@testable import VoiceDictationLib

final class WhisperCppEngineTests: XCTestCase {
    private let base = ModelID.whisperCppBase
    /// A fresh folder per test. The tests that decode read base.en from the
    /// app's own models folder instead, and never write there.
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-cpp-engine-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The pinned XCFramework is the release of the whisper-cli Danny chose (D2).
    /// Release b5454 and tag v1.9.5 are the same commit, d1be6fd (`git ls-remote`,
    /// 2026-11-13). It reports "1.9.5-dev" because v1.9.5's CMakeLists turns
    /// `WHISPER_BUILD_IS_DEV` on by default and the XCFramework build leaves it
    /// on; that option changes only the version string (Ruling T27-2).
    func testLinksWhisperCpp195() {
        XCTAssertEqual(String(cString: whisper_version()), "1.9.5-dev")
    }

    // MARK: - Models and the catalog

    func testOffersThreeModels() async throws {
        let engine = WhisperCppEngine(directory: directory)

        let empty = await engine.models()
        XCTAssertEqual(empty.map(\.id.storageKey), ["whisperCpp/tiny.en", "whisperCpp/base.en", "whisperCpp/small.en"])
        XCTAssertEqual(empty.map(\.state), [.notDownloaded, .notDownloaded, .notDownloaded])

        try makeFile("ggml-base.en.bin", bytes: 147_964_211)
        let whole = await engine.models().first { $0.id == base }
        XCTAssertEqual(whole?.state, .ready)
        XCTAssertEqual(whole?.bytesOnDisk, 147_964_211)

        try makeFile("ggml-base.en.bin", bytes: 147_964_210)
        let short = await engine.models().first { $0.id == base }
        XCTAssertEqual(short?.state, .notDownloaded)
    }

    func testCatalogMatchesHuggingFace() {
        let rows = GGMLModel.all.map {
            [$0.name, $0.fileName, String($0.bytes), $0.sha256, $0.technicalName, $0.detail, $0.url.absoluteString]
        }
        XCTAssertEqual(rows, [
            ["tiny.en", "ggml-tiny.en.bin", "77704715",
             "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f",
             "whisper.cpp tiny.en", "78 MB download — fastest, lower accuracy",
             "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin"],
            ["base.en", "ggml-base.en.bin", "147964211",
             "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
             "whisper.cpp base.en", "148 MB download — good balance",
             "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"],
            ["small.en", "ggml-small.en.bin", "487614201",
             "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
             "whisper.cpp small.en", "488 MB download — more accurate, slower",
             "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"],
        ])
        XCTAssertEqual(GGMLModel.all.map(\.plainName), ["Fastest", "Fast", "Slow"])
    }

    /// The speed ladder's names (spec 2026-11-22); the old names stay as the
    /// technical ones, for the Models page and the engine's own errors.
    func testModelsHavePlainNames() async {
        let models = await WhisperCppEngine(directory: directory).models()
        XCTAssertEqual(models.map(\.displayName), ["Fastest", "Fast", "Slow"])
        XCTAssertEqual(models.map(\.technicalName), ["whisper.cpp tiny.en", "whisper.cpp base.en", "whisper.cpp small.en"])
    }

    // MARK: - Before loading

    func testTranscribeWithoutModelThrowsModelNotReady() async {
        let clip = AudioClip(samples: [Float](repeating: 0.1, count: 16_000))
        do {
            _ = try await WhisperCppEngine(directory: directory).transcribe(clip, model: base, vocabulary: [])
            XCTFail("transcribe should throw")
        } catch {
            guard case .modelNotReady? = error as? TranscriptionError else { return XCTFail("threw \(error)") }
        }
    }

    func testEmptyClipGivesNoTextWithoutLoading() async throws {
        // Nothing is downloaded, so trying to load would throw.
        let engine = WhisperCppEngine(directory: directory)

        let text = try await engine.transcribe(AudioClip(samples: []), model: base, vocabulary: [])

        XCTAssertEqual(text, "")
        let loaded = await engine.loadedModels
        XCTAssertEqual(loaded, [])
    }

    // MARK: - Matching whisper-cli's settings (v1.9.5's examples/cli/cli.cpp)

    func testContextParamsMatchWhisperCLI() {
        let params = WhisperCppEngine.contextParams()

        XCTAssertTrue(params.use_gpu)
        XCTAssertTrue(params.flash_attn)
        XCTAssertEqual(params.gpu_device, 0)
        XCTAssertFalse(params.dtw_token_timestamps)
    }

    func testFullParamsMatchWhisperCLI() {
        "Tailscale, GV70".withCString { prompt in
            "en".withCString { language in
                let params = WhisperCppEngine.fullParams(prompt: prompt, language: language)
                let defaults = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

                XCTAssertEqual(params.strategy, WHISPER_SAMPLING_BEAM_SEARCH)
                XCTAssertEqual(params.beam_search.beam_size, 5)
                XCTAssertEqual(params.greedy.best_of, 5)

                XCTAssertEqual(params.temperature, 0)
                XCTAssertEqual(params.temperature_inc, 0.2)
                XCTAssertEqual(params.entropy_thold, 2.4)
                XCTAssertEqual(params.logprob_thold, -1)
                XCTAssertEqual(params.no_speech_thold, 0.6)

                XCTAssertTrue(params.no_timestamps)
                XCTAssertTrue(params.suppress_nst)
                XCTAssertTrue(params.no_context)

                XCTAssertFalse(params.translate)
                XCTAssertFalse(params.detect_language)
                XCTAssertFalse(params.carry_initial_prompt)
                XCTAssertFalse(params.token_timestamps)
                XCTAssertFalse(params.single_segment)

                XCTAssertEqual(params.max_len, 0)
                XCTAssertEqual(params.audio_ctx, 0)
                XCTAssertEqual(params.offset_ms, 0)
                XCTAssertEqual(params.duration_ms, 0)
                XCTAssertFalse(params.print_special)
                XCTAssertFalse(params.print_progress)
                XCTAssertFalse(params.print_realtime)
                XCTAssertFalse(params.print_timestamps)

                XCTAssertEqual(params.n_threads, defaults.n_threads)
                XCTAssertEqual(params.n_max_text_ctx, defaults.n_max_text_ctx)

                XCTAssertEqual(String(cString: params.language), "en")
                XCTAssertEqual(params.initial_prompt, prompt, "the string passed in, not a copy")
                XCTAssertEqual(String(cString: params.initial_prompt), "Tailscale, GV70")
            }
        }
    }

    func testPromptJoinsVocabularyAsWhisperCLIDid() {
        XCTAssertEqual(WhisperCppEngine.prompt(for: ["Tailscale", "GV70"]), "Tailscale, GV70")
        XCTAssertEqual(WhisperCppEngine.prompt(for: []), "")
    }

    /// whisper-cli read the 16-bit WAV that `writeWAV` wrote. Core Audio wrote
    /// each sample × 32768 rounded to the nearest integer, halves away from
    /// zero, clipped to Int16 (measured 2026-11-13). miniaudio read it back
    /// × 1/32768 (`ma_dr_wav_s16_to_f32` in v1.9.5's examples/miniaudio.h).
    func testInputIsRoundedTo16BitsAsTheWAVWas() throws {
        // The brief's samples, then two exact halves, which rounding halves
        // to even would turn into 2 and -18.
        let samples: [Float] = [0.123456789, -0.5, 0.99999, 1.2, -1.3, 0.00001, -0.00001, 2.5 / 32768, -18.5 / 32768]
        let wav = directory.appendingPathComponent("input.wav")
        try AudioClip(samples: samples).writeWAV(to: wav)

        let written = try Self.pcm16(of: wav)

        XCTAssertEqual(written, [4045, -16384, 32767, 32767, -32768, 0, 0, 3, -19])
        XCTAssertEqual(WhisperCppEngine.whisperInput(samples), written.map { Float($0) * (1.0 / 32768) })
    }

    // MARK: - The golden text (recorded from whisper-cli by WhisperCLIGoldenRecorder)

    func testMatchesWhisperCLIOnSample() async throws {
        let engine = try await engineWithBase()

        let text = try await engine.transcribe(try Self.sample(), model: base, vocabulary: [])

        XCTAssertEqual(OutputFilter.clean(text), try Self.golden("whisper-cli-base.en-sample.txt"))
    }

    func testMatchesWhisperCLIWithVocabulary() async throws {
        let engine = try await engineWithBase()

        let text = try await engine.transcribe(try Self.sample(), model: base, vocabulary: ["Quick Brown Fox", "Lazy Dog"])

        XCTAssertEqual(OutputFilter.clean(text), try Self.golden("whisper-cli-base.en-sample-vocabulary.txt"))
    }

    func testMatchesWhisperCLIAcrossTwoWindows() async throws {
        let engine = try await engineWithBase()

        let text = try await engine.transcribe(try Self.twoWindows(), model: base, vocabulary: [])

        XCTAssertEqual(OutputFilter.clean(text), try Self.golden("whisper-cli-base.en-sample-40s.txt"))
    }

    func testSameTextTwice() async throws {
        let engine = try await engineWithBase()
        let sample = try Self.sample()

        let first = try await engine.transcribe(sample, model: base, vocabulary: [])
        let second = try await engine.transcribe(sample, model: base, vocabulary: [])

        XCTAssertEqual(first, second)
    }

    // MARK: - Cancellation and unloading

    func testCancellationStopsPromptly() async throws {
        let engine = try await engineWithBase()
        let sample = try Self.sample()
        // Two minutes of speech in four windows.
        let twoMinutes = AudioClip(samples: Array(Array(repeating: sample.samples, count: 45).joined()))
        try await engine.prepare(base)

        // How long this Mac takes to decode the clip uncancelled. A cancel
        // that is not honoured only shows when that is clearly longer than
        // the bound below.
        let started = ContinuousClock.now
        _ = try await engine.transcribe(twoMinutes, model: base, vocabulary: [])
        let full = started.duration(to: .now).seconds
        guard full >= 0.5 else {
            throw XCTSkip("an uncancelled decode takes only \(full) s here, too fast to tell a cancel from a finish")
        }

        let task = Task { try await engine.transcribe(twoMinutes, model: base, vocabulary: []) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelled = ContinuousClock.now
        task.cancel()

        await assertCancelled(task, within: min(1, full / 2))
        XCTAssertLessThan(cancelled.duration(to: .now).seconds, full / 2, "cancel took as long as the decode")
        // A decode that failed to stop would still hold the context, and two
        // decodes on one context crash whisper.cpp; so wait it out first.
        _ = await task.result
        let after = try await engine.transcribe(sample, model: base, vocabulary: [])
        XCTAssertEqual(OutputFilter.clean(after), try Self.golden("whisper-cli-base.en-sample.txt"))
    }

    /// The engine alone, with no service to hold its slot: a second call
    /// waits for the context instead of crashing whisper.cpp.
    func testConcurrentTranscribesOnOneEngineBothFinish() async throws {
        let engine = try await engineWithBase()
        let sample = try Self.sample()
        try await engine.prepare(base)

        async let first = engine.transcribe(sample, model: base, vocabulary: [])
        async let second = engine.transcribe(sample, model: base, vocabulary: [])
        let texts = try await [first, second]

        let golden = try Self.golden("whisper-cli-base.en-sample.txt")
        XCTAssertEqual(texts.map(OutputFilter.clean), [golden, golden])
    }

    /// whisper-cli printed the segments' bytes as they were and the app
    /// decoded them once, so a character split across two segments is whole.
    func testSegmentsJoinBeforeDecoding() {
        XCTAssertEqual(WhisperContext.join([[0x63, 0x61, 0x66, 0xC3], [0xA9, 0x21]]), "café!")
        XCTAssertEqual(WhisperContext.join([]), "")
        XCTAssertEqual(WhisperContext.join([[0x61, 0xFF, 0x62]]), "a\u{FFFD}b")
    }

    func testUnloadDuringTranscriptionIsSafe() async throws {
        let engine = try await engineWithBase()
        let twoWindows = try Self.twoWindows()
        try await engine.prepare(base)

        let task = Task { try await engine.transcribe(twoWindows, model: base, vocabulary: []) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await engine.unload()

        let text = try await task.value
        XCTAssertEqual(OutputFilter.clean(text), try Self.golden("whisper-cli-base.en-sample-40s.txt"))
        let loaded = await engine.loadedModels
        XCTAssertEqual(loaded, [])
    }

    func testPrepareReportsPreparing() async throws {
        try makeFile("ggml-base.en.bin", bytes: 147_964_211)
        let engine = WhisperCppEngine(directory: directory, loader: { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return nil
        })

        let preparing = Task { try await engine.prepare(base) }
        try await waitUntil(engine, shows: base, as: .preparing)
        let during = await engine.models().first { $0.id == base }?.state
        XCTAssertEqual(during, .preparing)

        do {
            try await preparing.value
            XCTFail("prepare should fail when the loader does")
        } catch {
            guard case .modelNotReady? = error as? TranscriptionError else { return XCTFail("threw \(error)") }
        }
    }

    func testDecodeStopsAtItsDeadline() async throws {
        let engine = try await engineWithBase(timeout: { _ in 0.1 })
        let twoWindows = try Self.twoWindows()
        try await engine.prepare(base)

        let task = Task { try await engine.transcribe(twoWindows, model: base, vocabulary: []) }

        guard let result = await result(of: task, within: 1) else {
            return XCTFail("still decoding 1 s after it started")
        }
        switch result {
        case .success(let text):
            XCTFail("finished instead of timing out: \(text.prefix(40))")
        case .failure(let error):
            // The words the app has always used for a timeout, whisper-cli's.
            XCTAssertEqual(error as? TranscriptionError,
                           .failed("Transcription timed out — try a shorter recording or a smaller model"))
        }
    }

    // MARK: - Files (in the temporary folder only)

    func testDeleteRemovesTheFile() async throws {
        try makeFile("ggml-base.en.bin", bytes: 147_964_211)
        let engine = WhisperCppEngine(directory: directory)

        try await engine.delete(base)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ggml-base.en.bin").path))
        let after = await engine.models().first { $0.id == base }
        XCTAssertEqual(after?.state, .notDownloaded)
        XCTAssertNil(after?.bytesOnDisk)
    }

    func testDeleteWhilePreparingIsRefused() async throws {
        try makeFile("ggml-base.en.bin", bytes: 147_964_211)
        let gate = DispatchSemaphore(value: 0)
        let engine = WhisperCppEngine(directory: directory, loader: { _ in
            gate.wait()
            return nil
        })
        let preparing = Task { try await engine.prepare(base) }
        try await waitUntil(engine, shows: base, as: .preparing)

        do {
            try await engine.delete(base)
            XCTFail("delete should be refused while base.en prepares")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .failed("whisper.cpp base.en is still preparing"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ggml-base.en.bin").path))
        gate.signal()
        _ = await preparing.result
    }

    // MARK: - Downloads (a fake fetcher, in the temporary folder only)

    func testDownloadShowsProgressThenReady() async throws {
        let gate = AsyncStream.makeStream(of: Void.self)
        defer { gate.continuation.finish() }
        let engine = WhisperCppEngine(directory: directory, fetcher: { model, folder, progress in
            progress(0.5)
            for await _ in gate.stream {}
            try Self.makeSparseFile(folder.appendingPathComponent(model.fileName), bytes: UInt64(model.bytes))
        })
        let reported = Values()

        let download = Task { try await engine.download(base) { reported.append($0) } }
        try await waitUntil(engine, shows: base, as: .downloading(0.5))
        let during = await engine.models().first { $0.id == base }
        XCTAssertEqual(during?.state, .downloading(0.5))
        XCTAssertNil(during?.bytesOnDisk)

        gate.continuation.finish()
        try await download.value

        let after = await engine.models().first { $0.id == base }
        XCTAssertEqual(after?.state, .ready)
        XCTAssertEqual(after?.bytesOnDisk, 147_964_211)
        XCTAssertEqual(reported.all, [0.5, 1])
    }

    func testDownloadOfAPresentModelReturnsAtOnce() async throws {
        try makeFile("ggml-base.en.bin", bytes: 147_964_211)
        let fetches = Calls()
        let engine = WhisperCppEngine(directory: directory, fetcher: { _, _, _ in fetches.add() })
        let reported = Values()

        try await engine.download(base) { reported.append($0) }

        XCTAssertEqual(reported.all, [1])
        XCTAssertEqual(fetches.value, 0)
    }

    func testDeleteWhileDownloadingIsRefused() async throws {
        let gate = AsyncStream.makeStream(of: Void.self)
        defer { gate.continuation.finish() }
        // The whole file is there before the download has finished.
        let engine = WhisperCppEngine(directory: directory, fetcher: { model, folder, progress in
            try Self.makeSparseFile(folder.appendingPathComponent(model.fileName), bytes: UInt64(model.bytes))
            progress(0.5)
            for await _ in gate.stream {}
        })
        let download = Task { try await engine.download(base) { _ in } }
        try await waitUntil(engine, shows: base, as: .downloading(0.5))

        do {
            try await engine.delete(base)
            XCTFail("delete should be refused while base.en downloads")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .failed("whisper.cpp base.en is still downloading"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ggml-base.en.bin").path))
        gate.continuation.finish()
        try await download.value
    }

    /// A load must not start under a download, which may still fail and
    /// leave no file.
    func testPrepareWhileDownloadingIsRefused() async throws {
        let gate = AsyncStream.makeStream(of: Void.self)
        defer { gate.continuation.finish() }
        let loads = Calls()
        let engine = WhisperCppEngine(directory: directory, loader: { _ in
            loads.add()
            return nil
        }, fetcher: { model, folder, progress in
            // The whole file is there before the download has finished.
            try Self.makeSparseFile(folder.appendingPathComponent(model.fileName), bytes: UInt64(model.bytes))
            progress(0.5)
            for await _ in gate.stream {}
        })
        let download = Task { try await engine.download(base) { _ in } }
        try await waitUntil(engine, shows: base, as: .downloading(0.5))

        do {
            try await engine.prepare(base)
            XCTFail("prepare should be refused while base.en downloads")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .modelNotReady(
                "whisper.cpp base.en is still downloading. This recording is kept: re-transcribe it from the window when it's ready."))
        }

        XCTAssertEqual(loads.value, 0)
        gate.continuation.finish()
        try await download.value
    }

    /// The fetcher's own words reach the Models row as they are; a
    /// cancelled download ends in `CancellationError`. Either way the model
    /// reads Not downloaded after.
    func testAFailedOrCancelledDownloadLeavesTheModelNotDownloaded() async throws {
        let failing = WhisperCppEngine(directory: directory, fetcher: { _, _, _ in
            throw TranscriptionError.failed("whisper.cpp base.en could not be downloaded: HTTP 404")
        })
        do {
            try await failing.download(base) { _ in }
            XCTFail("download should throw")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .failed("whisper.cpp base.en could not be downloaded: HTTP 404"))
        }
        let afterFailure = await failing.models().first { $0.id == base }?.state
        XCTAssertEqual(afterFailure, .notDownloaded)

        let waiting = WhisperCppEngine(directory: directory, fetcher: { _, _, progress in
            progress(0.1)
            try await Task.sleep(for: .seconds(60))
        })
        let download = Task { try await waiting.download(base) { _ in } }
        try await waitUntil(waiting, shows: base, as: .downloading(0.1))
        download.cancel()
        do {
            try await download.value
            XCTFail("download should throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "threw \(error)")
        }
        let afterCancel = await waiting.models().first { $0.id == base }?.state
        XCTAssertEqual(afterCancel, .notDownloaded)
    }

    // MARK: - Deleting and downloading again (Ruling T27-4)

    /// In Task 27 a deleted whisper.cpp model could not come back. Now one
    /// that is not in use is deleted, reads Not downloaded, and downloads
    /// again.
    func testADeletedModelDownloadsAgain() async throws {
        let tiny = ModelID(engine: .whisperCpp, name: "tiny.en")
        try makeFile("ggml-tiny.en.bin", bytes: 77_704_715)
        let fetches = Calls()
        let engine = WhisperCppEngine(directory: directory, fetcher: { model, folder, progress in
            fetches.add()
            try Self.makeSparseFile(folder.appendingPathComponent(model.fileName), bytes: UInt64(model.bytes))
            progress(1)
        })
        let service = TranscriptionService(engines: [engine], selected: base)

        try await service.delete(tiny)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ggml-tiny.en.bin").path))
        let deleted = await engine.models().first { $0.id == tiny }?.state
        XCTAssertEqual(deleted, .notDownloaded)

        try await service.download(tiny) { _ in }

        XCTAssertEqual(fetches.value, 1)
        let downloaded = await engine.models().first { $0.id == tiny }
        XCTAssertEqual(downloaded?.state, .ready)
        XCTAssertEqual(downloaded?.bytesOnDisk, 77_704_715)
    }

    // MARK: - The time limit

    /// whisper-cli's limit, kept when its code went (Task 27A): 20 s at
    /// least, else three times the recording.
    func testTimeoutIsThreeTimesTheRecordingWithATwentySecondFloor() {
        XCTAssertEqual(WhisperCppEngine.timeout(recordingDuration: 1.0), 20.0)
        XCTAssertEqual(WhisperCppEngine.timeout(recordingDuration: 5.0), 20.0)
        XCTAssertEqual(WhisperCppEngine.timeout(recordingDuration: 10.0), 30.0)
    }

    // MARK: - Helpers

    /// Where the app keeps its ggml models, as the old app did.
    private static func appModels() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appending(path: "VoiceDictation/models", directoryHint: .isDirectory)
    }

    /// An engine on the app's own models, which it only reads; skips unless
    /// base.en is there whole.
    private func engineWithBase(timeout: (@Sendable (TimeInterval) -> TimeInterval)? = nil) async throws -> WhisperCppEngine {
        let models = try Self.appModels()
        let engine = timeout.map { WhisperCppEngine(directory: models, timeout: $0) } ?? WhisperCppEngine(directory: models)
        guard await engine.models().first(where: { $0.id == base })?.state == .ready else {
            throw XCTSkip("ggml-base.en.bin is not in \(models.path)")
        }
        return engine
    }

    /// A file of `bytes` bytes in the temporary folder, made sparse, so
    /// nothing is written.
    private func makeFile(_ name: String, bytes: UInt64) throws {
        try Self.makeSparseFile(directory.appendingPathComponent(name), bytes: bytes)
    }

    /// A file of `bytes` bytes at `url`, made sparse; a fake fetcher's
    /// download.
    private static func makeSparseFile(_ url: URL, bytes: UInt64) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: bytes)
    }

    /// Counts calls made from any thread.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }

    /// Progress reported from any thread, in order.
    private final class Values: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []

        var all: [Double] { lock.withLock { values } }
        func append(_ value: Double) { lock.withLock { values.append(value) } }
    }

    /// Waits at most 2 s for `models()` to show `id` in `state`.
    private func waitUntil(_ engine: WhisperCppEngine, shows id: ModelID, as state: ModelDescriptor.State) async throws {
        let deadline = Date().addingTimeInterval(2)
        while await engine.models().first(where: { $0.id == id })?.state != state, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The task's result, or nil if it is still running after `limit` seconds.
    private func result(of task: Task<String, Error>, within limit: TimeInterval) async -> Result<String, Error>? {
        let ended = XCTestExpectation(description: "transcribe ended")
        Task {
            _ = await task.result
            ended.fulfill()
        }
        guard await XCTWaiter().fulfillment(of: [ended], timeout: limit) == .completed else { return nil }
        return await task.result
    }

    /// Waits at most `limit` seconds for `task` and asserts it threw
    /// `CancellationError`. A hang fails the test instead of blocking the suite.
    private func assertCancelled(_ task: Task<String, Error>, within limit: TimeInterval,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        guard let result = await result(of: task, within: limit) else {
            return XCTFail("transcribe was still running \(limit) s after the cancel", file: file, line: line)
        }
        switch result {
        case .success(let text):
            XCTFail("finished instead of stopping: \(text.prefix(40))", file: file, line: line)
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "threw \(error)", file: file, line: line)
        }
    }

    /// The 16-bit samples in a WAV file's data chunk.
    private static func pcm16(of wav: URL) throws -> [Int16] {
        let data = try Data(contentsOf: wav)
        func int(at index: Int, bytes: Int) -> Int {
            (0..<bytes).reduce(0) { $0 | Int(data[index + $1]) << (8 * $1) }
        }
        var offset = 12  // past "RIFF", its size and "WAVE"
        while offset + 8 <= data.count {
            let size = int(at: offset + 4, bytes: 4)
            if data[offset..<offset + 4] == Data("data".utf8) {
                return stride(from: offset + 8, to: offset + 8 + size, by: 2).map {
                    Int16(truncatingIfNeeded: int(at: $0, bytes: 2))
                }
            }
            offset += 8 + size + (size & 1)
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    private static func sample() throws -> AudioClip {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "wav", subdirectory: "Resources"))
        return try AudioClip(contentsOf: url)
    }

    /// The sample 15 times, about 40 s: two of whisper's 30 s windows.
    private static func twoWindows() throws -> AudioClip {
        AudioClip(samples: Array(Array(repeating: try sample().samples, count: 15).joined()))
    }

    /// A golden file's text, exactly.
    private static func golden(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/golden"))
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
