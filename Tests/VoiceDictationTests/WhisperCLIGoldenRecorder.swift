import XCTest
@testable import VoiceDictationLib

/// Records what whisper-cli base.en, as the app ran it, makes of three clips,
/// for `WhisperCppEngineTests` to match (Task 27). It runs only on purpose:
///
///     VD_RECORD_WHISPER_GOLDEN=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///         swift test --filter WhisperCLIGoldenRecorder
///
/// Task 27A deletes it, with whisper-cli.
final class WhisperCLIGoldenRecorder: XCTestCase {
    func testRecordGolden() async throws {
        guard ProcessInfo.processInfo.environment["VD_RECORD_WHISPER_GOLDEN"] == "1" else {
            throw XCTSkip("Set VD_RECORD_WHISPER_GOLDEN=1 to record whisper-cli's text")
        }
        guard Transcriber.findBinaryPath() != nil else {
            throw XCTSkip("whisper-cli is not installed")
        }
        let models = ModelManager().modelDirectoryURL
        guard FileManager.default.fileExists(atPath: models.appendingPathComponent("ggml-base.en.bin").path) else {
            throw XCTSkip("ggml-base.en.bin is not in \(models.path)")
        }

        let engine = WhisperCLIEngine(modelDirectory: models)
        let base = ModelID(engine: .whisperCLI, name: "base.en")
        let sample = try Self.sample()
        // About 40 s: two of whisper's 30 s windows.
        let twoWindows = AudioClip(samples: Array(Array(repeating: sample.samples, count: 15).joined()))
        let cases: [(file: String, clip: AudioClip, vocabulary: [String])] = [
            ("whisper-cli-base.en-sample.txt", sample, []),
            // A vocabulary takes whisper-cli's --prompt path.
            ("whisper-cli-base.en-sample-vocabulary.txt", sample, ["Quick Brown Fox", "Lazy Dog"]),
            ("whisper-cli-base.en-sample-40s.txt", twoWindows, []),
        ]

        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/golden", isDirectory: true)
        try FileManager.default.createDirectory(at: golden, withIntermediateDirectories: true)
        for (file, clip, vocabulary) in cases {
            let text = try await engine.transcribe(clip, model: base, vocabulary: vocabulary)
            // Exactly the text, with no newline added.
            try Data(text.utf8).write(to: golden.appendingPathComponent(file))
        }
    }

    private static func sample() throws -> AudioClip {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "wav", subdirectory: "Resources"))
        return try AudioClip(contentsOf: url)
    }
}
