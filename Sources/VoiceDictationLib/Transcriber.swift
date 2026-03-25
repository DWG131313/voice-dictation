import Foundation

public protocol TranscriberDelegate: AnyObject {
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
            delegate?.transcriptionFailed(error: "whisper-cpp not found. Install via: brew install whisper-cpp")
            return
        }

        isTranscribing = true  // Set BEFORE dispatch to prevent race condition
        let timeout = Self.calculateTimeout(recordingDuration: recordingDuration)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = [
                "-m", self.modelPath,
                "-f", fileURL.path,
                "--no-timestamps"
            ]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    self.isTranscribing = false
                    self.delegate?.transcriptionFailed(error: "Failed to run whisper-cpp: \(error.localizedDescription)")
                    self.processQueue()
                }
                return
            }

            // Timeout handling
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                if process.isRunning {
                    process.terminate()
                }
            }
            timer.resume()

            // Read pipe data BEFORE waitUntilExit to avoid deadlock
            // (if whisper-cpp fills the pipe buffer, it blocks, and waitUntilExit never returns)
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            process.waitUntilExit()
            timer.cancel()

            // Clean up WAV file
            try? FileManager.default.removeItem(at: fileURL)

            let output = String(data: outputData, encoding: .utf8) ?? ""

            DispatchQueue.main.async {
                self.isTranscribing = false

                if process.terminationStatus != 0 {
                    let errString = String(data: errData, encoding: .utf8) ?? "Unknown error"
                    self.delegate?.transcriptionFailed(error: errString)
                } else {
                    let text = Self.parseOutput(output)
                    if !text.isEmpty {
                        self.delegate?.transcriptionCompleted(text: text)
                    }
                    // Empty text = silence, no paste needed
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

    public static func parseOutput(_ output: String) -> String {
        let lines = output.components(separatedBy: .newlines)
        var result: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip blank audio markers (check BEFORE bracket stripping)
            if trimmed == "[BLANK_AUDIO]" || trimmed.isEmpty {
                continue
            }

            var cleaned = trimmed

            // Remove timestamp brackets if present: [00:00:00.000 --> 00:00:03.000]
            if let bracketRange = cleaned.range(of: #"\[.*?\]"#, options: .regularExpression) {
                cleaned = String(cleaned[bracketRange.upperBound...])
            }

            cleaned = cleaned.trimmingCharacters(in: .whitespaces)

            if cleaned.isEmpty { continue }

            result.append(cleaned)
        }

        return result.joined(separator: " ")
    }

    public static func findBinaryPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp"
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    public static func calculateTimeout(recordingDuration: TimeInterval) -> TimeInterval {
        max(10.0, recordingDuration * 3.0)
    }
}
