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
        let cancelledAt = Date()
        task.cancel()

        do {
            let text = try await task.value
            XCTFail("\(model.storageKey) finished instead of stopping: \(text.prefix(40))")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1.0)
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
