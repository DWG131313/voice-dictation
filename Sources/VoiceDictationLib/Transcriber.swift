import Foundation

public protocol TranscriberDelegate: AnyObject {
    /// Called for every finished transcription. `text` is empty when whisper
    /// heard no speech — the caller should treat that as "nothing to paste".
    func transcriptionCompleted(text: String)
    func transcriptionFailed(error: String)
    func transcriptionQueueUpdated(count: Int)
    /// A queued recording was discarded because the queue was full. Called
    /// before its file is deleted.
    func transcriptionDropped(fileURL: URL)
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
            if let dropped = Self.enqueue((fileURL, recordingDuration), into: &queue, maxDepth: maxQueueDepth) {
                delegate?.transcriptionDropped(fileURL: dropped)
                try? FileManager.default.removeItem(at: dropped)
            }
            delegate?.transcriptionQueueUpdated(count: queue.count)
            return
        }

        runTranscription(fileURL: fileURL, recordingDuration: recordingDuration)
    }

    /// Appends to the waiting queue, dropping the oldest entry when full.
    /// Returns the dropped file, if any.
    static func enqueue(_ item: (URL, TimeInterval), into queue: inout [(URL, TimeInterval)], maxDepth: Int) -> URL? {
        var dropped: URL?
        if queue.count >= maxDepth {
            dropped = queue.removeFirst().0
        }
        queue.append(item)
        return dropped
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
            let outcome = WhisperRun(
                binaryPath: binaryPath,
                arguments: Self.arguments(modelPath: modelPath, audioPath: fileURL.path),
                timeout: timeout
            ).run()

            // Clean up WAV file
            try? FileManager.default.removeItem(at: fileURL)
            let elapsed = Date().timeIntervalSince(started)

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isTranscribing = false

                switch outcome {
                case .launchFailed(let error):
                    self.delegate?.transcriptionFailed(error: "Failed to run whisper-cli: \(error.localizedDescription)")
                case .timedOut:
                    Log.info("[WHISPER] Timed out after \(Int(timeout))s")
                    self.delegate?.transcriptionFailed(error: "Transcription timed out — try a shorter recording or a smaller model")
                case .cancelled:
                    break  // Transcriber never cancels a run
                case .finished(let output, let stderr, let status):
                    if status != 0 {
                        let message = Self.friendlyError(stderr: stderr, status: status)
                        Log.info("[WHISPER] Failed (status \(status)): \(stderr.suffix(500))")
                        self.delegate?.transcriptionFailed(error: message)
                    } else {
                        let text = Self.parseOutput(output)
                        Log.info("[WHISPER] Done in \(String(format: "%.1f", elapsed))s for \(String(format: "%.1f", recordingDuration))s audio, \(text.count) chars")
                        self.delegate?.transcriptionCompleted(text: text)
                    }
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

    public static func parseOutput(_ output: String) -> String {
        OutputFilter.clean(output)
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
