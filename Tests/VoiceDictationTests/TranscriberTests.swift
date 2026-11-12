import XCTest
@testable import VoiceDictationLib

final class TranscriberTests: XCTestCase {
    func testOverflowDropsOldestQueuedRecording() {
        let urls = (1...5).map { URL(fileURLWithPath: "/tmp/\($0).wav") }
        var queue: [(URL, TimeInterval)] = []
        var dropped: [URL] = []
        for url in urls.prefix(3) {
            XCTAssertNil(Transcriber.enqueue((url, 1), into: &queue, maxDepth: 3))
        }
        for url in urls.suffix(2) {
            if let d = Transcriber.enqueue((url, 1), into: &queue, maxDepth: 3) { dropped.append(d) }
        }
        XCTAssertEqual(dropped, [urls[0], urls[1]])
        XCTAssertEqual(queue.map { $0.0 }, [urls[2], urls[3], urls[4]])
    }

    func testParseWhisperOutput() {
        let output = """
        [00:00:00.000 --> 00:00:03.000]   Hello, this is a test.
        [00:00:03.000 --> 00:00:05.000]   Second sentence.
        """
        let result = Transcriber.parseOutput(output)
        XCTAssertEqual(result, "Hello, this is a test. Second sentence.")
    }

    func testParseWhisperOutputNoTimestamps() {
        let output = "  Hello, this is a test.\n  Second sentence.\n"
        let result = Transcriber.parseOutput(output)
        XCTAssertEqual(result, "Hello, this is a test. Second sentence.")
    }

    func testParseEmptyOutput() {
        let result = Transcriber.parseOutput("")
        XCTAssertEqual(result, "")
    }

    func testParseWhisperOutputWithBlankAudio() {
        let output = "[BLANK_AUDIO]\n"
        let result = Transcriber.parseOutput(output)
        XCTAssertEqual(result, "")
    }

    func testParseDropsNonSpeechTokenLines() {
        let output = "[Music]\n(silence)\n*whoosh*\n Real words here.\n[inaudible]\n"
        XCTAssertEqual(Transcriber.parseOutput(output), "Real words here.")
    }

    func testParseKeepsBracketsInsideSpeech() {
        // Only a leading timestamp is stripped — brackets the user actually
        // dictated (or whisper placed mid-sentence) must survive intact.
        let output = "[00:00:00.000 --> 00:00:02.000]  Open bracket [x] close bracket."
        XCTAssertEqual(Transcriber.parseOutput(output), "Open bracket [x] close bracket.")

        let noStamp = "Array index [0] is first."
        XCTAssertEqual(Transcriber.parseOutput(noStamp), "Array index [0] is first.")
    }

    func testParseDropsSilenceHallucinations() {
        XCTAssertEqual(Transcriber.parseOutput("\n you"), "")
        XCTAssertEqual(Transcriber.parseOutput(" Thank you."), "")
        XCTAssertEqual(Transcriber.parseOutput(" Thanks for watching!"), "")
        // A real sentence that merely contains the phrase is untouched.
        XCTAssertEqual(Transcriber.parseOutput(" Thank you for the help today."), "Thank you for the help today.")
    }

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
