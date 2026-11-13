import Foundation

/// The whisper-cli helpers `WhisperCLIEngine` runs it with: finding the
/// binary, its arguments, its timeout, and its errors in words fit for the
/// menu bar. The engine cleans its output with `OutputFilter`. The queue that
/// ran whisper-cli for the old app is gone; `DictationPipeline` lines
/// dictations up now.
public enum Transcriber {
    public static func arguments(modelPath: String, audioPath: String, vocabulary: [String] = []) -> [String] {
        var args = [
            "-m", modelPath,
            "-f", audioPath,
            "--no-timestamps",
            "--no-prints",      // only the transcript on stdout
            "--suppress-nst",   // suppress non-speech tokens like [MUSIC]
            "--language", "en",
        ]
        if !vocabulary.isEmpty {
            args += ["--prompt", vocabulary.joined(separator: ", ")]
        }
        return args
    }

    /// Turn whisper's stderr dump into a one-line message fit for the menu bar.
    public static func friendlyError(stderr: String, status: Int32) -> String {
        let lower = stderr.lowercased()
        if lower.contains("failed to load model") || (lower.contains("failed to open") && lower.contains(".bin")) {
            return "Model file missing or corrupt — re-select the model in Preferences to re-download"
        }
        if lower.contains("failed to read audio") || lower.contains("error: failed to read") {
            return "Could not read the recording"
        }
        if status == 9 || lower.contains("killed") {
            return "whisper-cli was killed (status 9) — the binary may be blocked by macOS security"
        }
        let lastLine = stderr
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("ggml_") && !$0.hasPrefix("load_backend") }
        if let lastLine = lastLine {
            return "Transcription failed: \(lastLine.prefix(120))"
        }
        return "Transcription failed (exit status \(status))"
    }

    public static func findBinaryPath() -> String? {
        BundledBinary.findWhisperCLI()
    }

    /// The formula lives in `WhisperCppEngine` now, which keeps whisper-cli's
    /// limit after Task 27A deletes this file.
    public static func calculateTimeout(recordingDuration: TimeInterval) -> TimeInterval {
        WhisperCppEngine.timeout(recordingDuration: recordingDuration)
    }
}
