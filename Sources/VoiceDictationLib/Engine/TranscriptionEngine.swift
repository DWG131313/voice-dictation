import Foundation

public enum TranscriptionError: Error, Equatable {
    case modelNotReady(String), engineUnavailable(String), cancelled, failed(String)
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
