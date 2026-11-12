import XCTest
@testable import VoiceDictationLib

final class TranscriberTests: XCTestCase {
    func testFriendlyErrorForMissingModel() {
        let stderr = "whisper_init_from_file_with_params_no_state: loading model from '/x/ggml-base.en.bin'\nwhisper_model_load: failed to open '/x/ggml-base.en.bin'\nerror: failed to load model\n"
        let message = Transcriber.friendlyError(stderr: stderr, status: 3)
        XCTAssertTrue(message.contains("Model file missing"), message)
    }

    func testFriendlyErrorFallsBackToLastMeaningfulLine() {
        let stderr = "ggml_metal_init: allocating\nsomething went wrong here\n\n"
        let message = Transcriber.friendlyError(stderr: stderr, status: 1)
        XCTAssertEqual(message, "Transcription failed: something went wrong here")
    }

    func testFriendlyErrorWithEmptyStderr() {
        XCTAssertEqual(Transcriber.friendlyError(stderr: "", status: 2), "Transcription failed (exit status 2)")
    }

    func testArgumentsSuppressNoiseAndPinLanguage() {
        let args = Transcriber.arguments(modelPath: "/m.bin", audioPath: "/a.wav")
        XCTAssertEqual(args.prefix(4), ["-m", "/m.bin", "-f", "/a.wav"])
        XCTAssertTrue(args.contains("--no-timestamps"))
        XCTAssertTrue(args.contains("--no-prints"))
        XCTAssertTrue(args.contains("--suppress-nst"))
    }

    func testFindBinaryPath() {
        // This test verifies the resolution logic doesn't crash
        // Whether it finds a binary depends on the test environment
        _ = Transcriber.findBinaryPath()
    }

    func testTimeoutCalculation() {
        XCTAssertEqual(Transcriber.calculateTimeout(recordingDuration: 1.0), 20.0)
        XCTAssertEqual(Transcriber.calculateTimeout(recordingDuration: 5.0), 20.0)
        XCTAssertEqual(Transcriber.calculateTimeout(recordingDuration: 10.0), 30.0)
    }
}
