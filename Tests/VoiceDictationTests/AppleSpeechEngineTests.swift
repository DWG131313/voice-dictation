import Speech
import XCTest
@testable import VoiceDictationLib

final class AppleSpeechEngineTests: XCTestCase {
    func testModelStateReflectsAssets() async {
        let models = await AppleSpeechEngine().models()

        XCTAssertEqual(models.map(\.id), [.appleSpeech, .appleDictation])
        XCTAssertEqual(models.map(\.displayName), ["Apple Speech", "Apple Dictation"])
        for model in models {
            switch model.state {
            case .ready, .notDownloaded, .unavailable:
                break
            case .downloading, .preparing:
                XCTFail("\(model.displayName) is \(model.state)")
            }
        }
    }

    func testTranscribesSampleWithAppleSpeech() async throws {
        try await assertTranscribesSample(.appleSpeech)
    }

    func testTranscribesSampleWithAppleDictation() async throws {
        try await assertTranscribesSample(.appleDictation)
    }

    func testCancellationStopsAppleSpeechPromptly() async throws {
        try await assertCancellationStopsPromptly(.appleSpeech)
    }

    func testCancellationStopsAppleDictationPromptly() async throws {
        try await assertCancellationStopsPromptly(.appleDictation)
    }

    func testCancellationDuringSetupStopsPromptly() async throws {
        // Never prepared, and a vocabulary: setup takes 70 ms or more, so the cancel lands in it.
        try await assertCancellationDuringSetup(prepared: false)
    }

    func testCancellationDuringVocabularySetupStopsPromptly() async throws {
        // Prepared, so the cancel lands in Apple Dictation's 70 ms or more of vocabulary setup.
        try await assertCancellationDuringSetup(prepared: true)
    }

    func testEmptyClipGivesNoText() async throws {
        for model in [ModelID.appleSpeech, .appleDictation] {
            try await skipUnlessInstalled(model)
            let text = try await AppleSpeechEngine().transcribe(AudioClip(samples: []), model: model, vocabulary: [])
            XCTAssertEqual(text, "", model.storageKey)
        }
    }

    func testTranscribesAgainAfterUnload() async throws {
        let clip = try sample()
        let engine = AppleSpeechEngine()
        for model in [ModelID.appleSpeech, .appleDictation] {
            try await skipUnlessInstalled(model)
            try await engine.prepare(model)
        }

        await engine.unload()

        for model in [ModelID.appleSpeech, .appleDictation] {
            let text = try await engine.transcribe(clip, model: model, vocabulary: [])
            XCTAssertTrue(text.lowercased().contains("quick brown fox"), "\(model.storageKey) heard: \(text)")
        }
    }

    func testUnknownModelIsNotReady() async {
        let unknown = ModelID(engine: .appleSpeech, name: "fr-FR")
        let engine = AppleSpeechEngine()
        do {
            try await engine.prepare(unknown)
            XCTFail("prepare should throw")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .modelNotReady("Unknown model appleSpeech/fr-FR"))
        }
        do {
            _ = try await engine.transcribe(AudioClip(samples: [0.1]), model: unknown, vocabulary: [])
            XCTFail("transcribe should throw")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .modelNotReady("Unknown model appleSpeech/fr-FR"))
        }
    }

    func testPhrasesJoinWithOneSpace() {
        XCTAssertEqual(AppleSpeechEngine.joinPhrases([]), "")
        XCTAssertEqual(AppleSpeechEngine.joinPhrases(["Only one."]), "Only one.")
        XCTAssertEqual(AppleSpeechEngine.joinPhrases(["First.", "Second."]), "First. Second.")
        XCTAssertEqual(AppleSpeechEngine.joinPhrases(["First.", " Second."]), "First. Second.")
        XCTAssertEqual(AppleSpeechEngine.joinPhrases(["First. ", "Second."]), "First. Second.")
        XCTAssertEqual(AppleSpeechEngine.joinPhrases(["First.\n", "Second."]), "First.\nSecond.")
        XCTAssertEqual(AppleSpeechEngine.joinPhrases(["one", "", "two"]), "one two")
    }

    func testDeleteIsLeftToMacOS() async {
        do {
            try await AppleSpeechEngine().delete(.appleSpeech)
            XCTFail("delete should throw")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .failed("Managed by macOS"))
        }
    }

    // MARK: - Helpers

    private func assertTranscribesSample(_ model: ModelID) async throws {
        try await skipUnlessInstalled(model)
        let clip = try sample()
        let engine = AppleSpeechEngine()
        try await engine.prepare(model)

        // A vocabulary takes the contextual-strings path; none of its words are spoken.
        let text = try await engine.transcribe(clip, model: model, vocabulary: ["Prism", "WhisperKit"])

        XCTAssertTrue(text.lowercased().contains("quick brown fox"), "\(model.storageKey) heard: \(text)")
    }

    private func assertCancellationStopsPromptly(_ model: ModelID) async throws {
        try await skipUnlessInstalled(model)
        let speech = try sample().samples
        // Two minutes of speech: far more than either model gets through in 100 ms.
        let long = AudioClip(samples: Array(Array(repeating: speech, count: 45).joined()))
        let engine = AppleSpeechEngine()
        try await engine.prepare(model)

        let task = Task { try await engine.transcribe(long, model: model, vocabulary: []) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        await assertCancelled(task, within: 1)
    }

    /// Cancels an Apple Dictation transcription with a vocabulary 10 ms in,
    /// before any audio reaches an analyzer.
    private func assertCancellationDuringSetup(prepared: Bool) async throws {
        try await skipUnlessInstalled(.appleDictation)
        let clip = try sample()
        let engine = AppleSpeechEngine()
        if prepared { try await engine.prepare(.appleDictation) }

        let task = Task { try await engine.transcribe(clip, model: .appleDictation, vocabulary: ["Prism", "WhisperKit"]) }
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        await assertCancelled(task, within: 1)
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

    /// Skips unless this Mac supports the model for en-US and its language
    /// files are installed for this process. macOS reserves them per app, so
    /// files already on the Mac for another app do not count.
    private func skipUnlessInstalled(_ model: ModelID) async throws {
        let english = Locale(identifier: "en-US")
        let module: any SpeechModule
        if model == .appleDictation {
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: english) else {
                throw XCTSkip("DictationTranscriber does not support en-US on this Mac")
            }
            module = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                          reportingOptions: [], attributeOptions: [])
        } else {
            guard SpeechTranscriber.isAvailable else {
                throw XCTSkip("SpeechTranscriber is not available on this Mac")
            }
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: english) else {
                throw XCTSkip("SpeechTranscriber does not support en-US on this Mac")
            }
            module = SpeechTranscriber(locale: locale, preset: .transcription)
        }
        let status = await AssetInventory.status(forModules: [module])
        guard status == .installed else {
            throw XCTSkip("\(model.storageKey): en-US language files are not installed for this test process "
                + "(status: \(status)). See Task 6 in docs/superpowers/plans/2026-11-11-native-app-notes.md.")
        }
    }
}
