import Foundation

public protocol TranscriberDelegate: AnyObject {
    /// Called for every finished transcription. `text` is empty when whisper
    /// heard no speech — the caller should treat that as "nothing to paste".
    func transcriptionCompleted(text: String)
    func transcriptionFailed(error: String)
    func transcriptionQueueUpdated(count: Int)
}

public class Transcriber {
    public weak var delegate: TranscriberDelegate?

    private var modelPath: String
    private var queue: [(URL, TimeInterval)] = []
    private var isTranscribing = false
    private let maxQueueDepth = 3

    public init(modelPath: String) {
        self.modelPath = modelPath
    }

    public func transcribe(fileURL: URL, recordingDuration: TimeInterval) {
        if isTranscribing {
            if queue.count >= maxQueueDepth {
                // Drop oldest
                let dropped = queue.removeFirst()
                try? FileManager.default.removeItem(at: dropped.0)
            }
            queue.append((fileURL, recordingDuration))
            delegate?.transcriptionQueueUpdated(count: queue.count)
            return
        }

        runTranscription(fileURL: fileURL, recordingDuration: recordingDuration)
    }

    private func runTranscription(fileURL: URL, recordingDuration: TimeInterval) {
        guard let binaryPath = Self.findBinaryPath() else {
            try? FileManager.default.removeItem(at: fileURL)
            delegate?.transcriptionFailed(error: "whisper-cli not found. Install via: brew install whisper-cpp")
            processQueue()
            return
        }

        isTranscribing = true  // Set BEFORE dispatch to prevent race condition
        let timeout = Self.calculateTimeout(recordingDuration: recordingDuration)
        let modelPath = self.modelPath
        let started = Date()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = Self.arguments(modelPath: modelPath, audioPath: fileURL.path)

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isTranscribing = false
                    self.delegate?.transcriptionFailed(error: "Failed to run whisper-cli: \(error.localizedDescription)")
                    self.processQueue()
                }
                return
            }

            // Timeout handling
            var timedOut = false
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                if process.isRunning {
                    timedOut = true
                    process.terminate()
                }
            }
            timer.resume()

            // Drain both pipes concurrently. Reading them one after the other
            // can deadlock: whisper blocks writing to a full stderr pipe while
            // we block waiting for stdout to close.
            var errData = Data()
            let errGroup = DispatchGroup()
            errGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                errGroup.leave()
            }
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            errGroup.wait()

            process.waitUntilExit()
            timer.cancel()

            // Clean up WAV file
            try? FileManager.default.removeItem(at: fileURL)

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            let elapsed = Date().timeIntervalSince(started)

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isTranscribing = false

                if timedOut {
                    Log.info("[WHISPER] Timed out after \(Int(timeout))s")
                    self.delegate?.transcriptionFailed(error: "Transcription timed out — try a shorter recording or a smaller model")
                } else if process.terminationStatus != 0 {
                    let message = Self.friendlyError(stderr: stderr, status: process.terminationStatus)
                    Log.info("[WHISPER] Failed (status \(process.terminationStatus)): \(stderr.suffix(500))")
                    self.delegate?.transcriptionFailed(error: message)
                } else {
                    let text = Self.parseOutput(output)
                    Log.info("[WHISPER] Done in \(String(format: "%.1f", elapsed))s for \(String(format: "%.1f", recordingDuration))s audio, \(text.count) chars")
                    self.delegate?.transcriptionCompleted(text: text)
                }

                self.processQueue()
            }
        }
    }

    private func processQueue() {
        guard !queue.isEmpty else { return }

        let (fileURL, duration) = queue.removeFirst()
        delegate?.transcriptionQueueUpdated(count: queue.count)

        // Small delay between queued transcriptions
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.runTranscription(fileURL: fileURL, recordingDuration: duration)
        }
    }

    // MARK: - Static helpers (testable)

    public static func arguments(modelPath: String, audioPath: String) -> [String] {
        [
            "-m", modelPath,
            "-f", audioPath,
            "--no-timestamps",
            "--no-prints",      // only the transcript on stdout
            "--suppress-nst",   // suppress non-speech tokens like [MUSIC]
            "--language", "en",
        ]
    }

    /// Tokens whisper emits for non-speech audio. A line that is nothing but
    /// one of these is dropped so silence never pastes "[BLANK_AUDIO]".
    private static let nonSpeechLine = try! NSRegularExpression(
        pattern: #"^\s*(\[[^\]]*\]|\([^)]*\)|\*[^*]*\*)\s*$"#
    )

    /// A leading whisper timestamp: `[00:00:00.000 --> 00:00:03.000]`
    private static let leadingTimestamp = try! NSRegularExpression(
        pattern: #"^\s*\[\d{2}:\d{2}:\d{2}\.\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}\.\d{3}\]"#
    )

    /// Whole-transcript outputs whisper produces from silence or breath noise.
    /// Compared after lowercasing and stripping punctuation, and only against
    /// the entire transcript, so real sentences are never touched.
    private static let silenceHallucinations: Set<String> = [
        "you", "thank you", "thanks for watching", "thank you for watching",
        "thanks for listening", "bye", "the end",
    ]

    public static func parseOutput(_ output: String) -> String {
        let text = joinLines(output)
        let normalized = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if silenceHallucinations.contains(normalized) { return "" }
        return text
    }

    private static func joinLines(_ output: String) -> String {
        var result: [String] = []

        for line in output.components(separatedBy: .newlines) {
            var cleaned = line

            // Strip a leading timestamp only — never brackets inside the text.
            let full = NSRange(cleaned.startIndex..., in: cleaned)
            if let match = leadingTimestamp.firstMatch(in: cleaned, range: full),
               let range = Range(match.range, in: cleaned) {
                cleaned.removeSubrange(range)
            }

            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            if cleaned.isEmpty { continue }

            let range = NSRange(cleaned.startIndex..., in: cleaned)
            if nonSpeechLine.firstMatch(in: cleaned, range: range) != nil { continue }

            result.append(cleaned)
        }

        return result.joined(separator: " ")
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

    public static func calculateTimeout(recordingDuration: TimeInterval) -> TimeInterval {
        // Generous floor: the first run after a cold start pays for model
        // loading and Metal shader compilation.
        max(20.0, recordingDuration * 3.0)
    }
}
