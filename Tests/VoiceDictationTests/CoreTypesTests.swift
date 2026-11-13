import XCTest
@testable import VoiceDictationLib

final class CoreTypesTests: XCTestCase {
    func testStorageKeyRoundTrip() {
        let id = ModelID(engine: .whisperKit, name: "large-v3-turbo")
        XCTAssertEqual(id.storageKey, "whisperKit/large-v3-turbo")
        XCTAssertEqual(ModelID(storageKey: "whisperKit/large-v3-turbo"), id)
    }

    func testStorageKeyRejectsGarbage() {
        XCTAssertNil(ModelID(storageKey: "nope"))
    }

    /// Final fix wave, E1: wherever a transcription error is shown (a step
    /// in the Welcome window, a model's row, a log line), it reads as its
    /// reason, never "The operation couldn't be completed…".
    func testATranscriptionErrorReadsAsItsReason() {
        XCTAssertEqual(TranscriptionError.modelNotReady("whisper.cpp base.en is not downloaded").localizedDescription,
                       "whisper.cpp base.en is not downloaded")
        XCTAssertEqual(TranscriptionError.engineUnavailable("No engine runs whisperCLI/base.en").localizedDescription,
                       "No engine runs whisperCLI/base.en")
        XCTAssertEqual(TranscriptionError.failed("whisper.cpp small.en could not be downloaded: HTTP 404").localizedDescription,
                       "whisper.cpp small.en could not be downloaded: HTTP 404")
    }

    func testClipDurationAndPeak() {
        var samples = [Float](repeating: 0, count: 16_000)
        samples[100] = 0.5
        let clip = AudioClip(samples: samples)
        XCTAssertEqual(clip.duration, 1.0, accuracy: 0.0001)
        XCTAssertEqual(clip.peak, 0.5, accuracy: 0.0001)
    }
}
