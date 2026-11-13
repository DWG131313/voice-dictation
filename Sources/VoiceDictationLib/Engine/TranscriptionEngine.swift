import Foundation

/// Why a model could not be prepared, used, downloaded or deleted. Each case
/// carries its reason in plain words, and that reason is what the error reads
/// as wherever it is shown (`localizedDescription`), never "The operation
/// couldn't be completed…".
public enum TranscriptionError: Error, Equatable {
    case modelNotReady(String), engineUnavailable(String), failed(String)

    /// A model's load refused while its download runs, so a dictation made
    /// meanwhile fails at once and is kept as Failed with its recording
    /// (Review Focus 1).
    static func stillDownloading(_ model: String) -> TranscriptionError {
        .modelNotReady("\(model) is still downloading. This recording is kept: re-transcribe it from the window when it's ready.")
    }
}

extension TranscriptionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .modelNotReady(let reason), .engineUnavailable(let reason), .failed(let reason): reason
        }
    }
}

public protocol TranscriptionEngine: Sendable {
    var kind: EngineKind { get }
    func models() async -> [ModelDescriptor]
    /// Load and keep warm.
    func prepare(_ model: ModelID) async throws
    /// Must stop promptly and throw `CancellationError` when its task is cancelled.
    func transcribe(_ clip: AudioClip, model: ModelID, vocabulary: [String]) async throws -> String
    func download(_ model: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws
    func delete(_ model: ModelID) async throws
    func unload() async
}
