import Foundation

/// The original whisper-cli path behind `TranscriptionEngine`. It lists the
/// three `ggml-*.en.bin` files already in the models folder and never
/// downloads: the engine goes away once Danny picks a default.
public final class WhisperCLIEngine: TranscriptionEngine {
    public let kind = EngineKind.whisperCLI

    private let modelDirectory: URL
    private static let notDownloaded = "Previous engine: model not downloaded"

    public init(modelDirectory: URL = ModelManager().modelDirectoryURL) {
        self.modelDirectory = modelDirectory
    }

    public func models() async -> [ModelDescriptor] {
        PreferencesManager.WhisperModel.available.map { model in
            let id = ModelID(engine: .whisperCLI, name: model.id)
            let size = fileSize(of: model.fileName)
            return ModelDescriptor(
                id: id,
                displayName: model.displayName,
                detail: model.sizeDescription,
                state: size == nil ? .unavailable(Self.notDownloaded) : .ready,
                bytesOnDisk: size
            )
        }
    }

    public func prepare(_ model: ModelID) async throws {
        _ = try modelURL(for: model)
    }

    public func transcribe(_ clip: AudioClip, model: ModelID, vocabulary: [String]) async throws -> String {
        try Task.checkCancellation()
        let modelURL = try modelURL(for: model)
        guard let binaryPath = Transcriber.findBinaryPath() else {
            throw TranscriptionError.engineUnavailable("whisper-cli not found. Install via: brew install whisper-cpp")
        }

        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("vd-whisper-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try clip.writeWAV(to: wav)

        let timeout = Transcriber.calculateTimeout(recordingDuration: clip.duration)
        let run = WhisperRun(
            binaryPath: binaryPath,
            arguments: Transcriber.arguments(modelPath: modelURL.path, audioPath: wav.path, vocabulary: vocabulary),
            timeout: timeout
        )
        let outcome: WhisperRun.Outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: run.run())
                }
            }
        } onCancel: {
            run.cancel()
        }
        try Task.checkCancellation()

        switch outcome {
        case .cancelled:
            throw CancellationError()
        case .launchFailed(let error):
            throw TranscriptionError.failed("Failed to run whisper-cli: \(error.localizedDescription)")
        case .timedOut:
            throw TranscriptionError.failed("Transcription timed out — try a shorter recording or a smaller model")
        case .finished(let stdout, let stderr, let status):
            guard status == 0 else {
                throw TranscriptionError.failed(Transcriber.friendlyError(stderr: stderr, status: status))
            }
            return OutputFilter.clean(stdout)
        }
    }

    public func download(_ model: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        throw TranscriptionError.failed("The previous engine cannot download models")
    }

    public func delete(_ model: ModelID) async throws {
        guard let fileName = fileName(for: model) else { return }
        try? FileManager.default.removeItem(at: modelDirectory.appendingPathComponent(fileName))
    }

    public func unload() async {}

    // MARK: - Helpers

    private func fileName(for model: ModelID) -> String? {
        guard model.engine == .whisperCLI else { return nil }
        return PreferencesManager.WhisperModel.available.first { $0.id == model.name }?.fileName
    }

    private func fileSize(of fileName: String) -> Int64? {
        let path = modelDirectory.appendingPathComponent(fileName).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }

    private func modelURL(for model: ModelID) throws -> URL {
        guard let fileName = fileName(for: model) else {
            throw TranscriptionError.modelNotReady("Unknown model \(model.storageKey)")
        }
        guard fileSize(of: fileName) != nil else {
            throw TranscriptionError.modelNotReady(Self.notDownloaded)
        }
        return modelDirectory.appendingPathComponent(fileName)
    }
}
