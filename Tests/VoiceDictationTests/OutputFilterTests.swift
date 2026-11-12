import XCTest
@testable import VoiceDictationLib

final class OutputFilterTests: XCTestCase {
    func testParseWhisperOutput() {
        let output = """
        [00:00:00.000 --> 00:00:03.000]   Hello, this is a test.
        [00:00:03.000 --> 00:00:05.000]   Second sentence.
        """
        let result = OutputFilter.clean(output)
        XCTAssertEqual(result, "Hello, this is a test. Second sentence.")
    }

    func testParseWhisperOutputNoTimestamps() {
        let output = "  Hello, this is a test.\n  Second sentence.\n"
        let result = OutputFilter.clean(output)
        XCTAssertEqual(result, "Hello, this is a test. Second sentence.")
    }

    func testParseEmptyOutput() {
        let result = OutputFilter.clean("")
        XCTAssertEqual(result, "")
    }

    func testParseWhisperOutputWithBlankAudio() {
        let output = "[BLANK_AUDIO]\n"
        let result = OutputFilter.clean(output)
        XCTAssertEqual(result, "")
    }

    func testParseDropsNonSpeechTokenLines() {
        let output = "[Music]\n(silence)\n*whoosh*\n Real words here.\n[inaudible]\n"
        XCTAssertEqual(OutputFilter.clean(output), "Real words here.")
    }

    func testParseKeepsBracketsInsideSpeech() {
        // Only a leading timestamp is stripped — brackets the user actually
        // dictated (or whisper placed mid-sentence) must survive intact.
        let output = "[00:00:00.000 --> 00:00:02.000]  Open bracket [x] close bracket."
        XCTAssertEqual(OutputFilter.clean(output), "Open bracket [x] close bracket.")

        let noStamp = "Array index [0] is first."
        XCTAssertEqual(OutputFilter.clean(noStamp), "Array index [0] is first.")
    }

    func testParseDropsSilenceHallucinations() {
        XCTAssertEqual(OutputFilter.clean("\n you"), "")
        XCTAssertEqual(OutputFilter.clean(" Thank you."), "")
        XCTAssertEqual(OutputFilter.clean(" Thanks for watching!"), "")
        // A real sentence that merely contains the phrase is untouched.
        XCTAssertEqual(OutputFilter.clean(" Thank you for the help today."), "Thank you for the help today.")
    }

    func testHallucinationAppliesToAnyEngine() {
        XCTAssertEqual(OutputFilter.clean(" Thank you. "), "")
    }

    func testBlankAudioThenAHallucinationCleansToNothing() {
        XCTAssertEqual(OutputFilter.clean("[BLANK_AUDIO]\n Thank you."), "")
    }

    func testCancellationStopsProcess() async throws {
        let modelsDir = ModelManager().modelDirectoryURL
        let modelFile = modelsDir.appendingPathComponent("ggml-base.en.bin")
        try XCTSkipUnless(Transcriber.findBinaryPath() != nil, "whisper-cli not installed")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelFile.path), "base.en model not installed")

        let engine = WhisperCLIEngine(modelDirectory: modelsDir)
        let silence = AudioClip(samples: [Float](repeating: 0, count: 30 * 16_000))
        let model = ModelID(engine: .whisperCLI, name: "base.en")

        let task = Task { try await engine.transcribe(silence, model: model, vocabulary: []) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1.0)
        }
    }

    func testModelsListReadyAndUnavailable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wce-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 1234).write(to: dir.appendingPathComponent("ggml-base.en.bin"))
        let engine = WhisperCLIEngine(modelDirectory: dir)

        let models = await engine.models()
        XCTAssertEqual(models.map(\.id.name), ["tiny.en", "base.en", "small.en"])
        XCTAssertEqual(models[1].state, .ready)
        XCTAssertEqual(models[1].bytesOnDisk, 1234)
        XCTAssertEqual(models[0].state, .unavailable("Previous engine: model not downloaded"))

        do {
            try await engine.prepare(models[0].id)
            XCTFail("expected modelNotReady")
        } catch let error as TranscriptionError {
            guard case .modelNotReady = error else { return XCTFail("\(error)") }
        }
        try await engine.delete(models[1].id)
        let after = await engine.models()
        XCTAssertEqual(after[1].state, .unavailable("Previous engine: model not downloaded"))
    }
}
