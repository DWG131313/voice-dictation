import Foundation

public enum EngineKind: String, Codable, Sendable, CaseIterable {
    case appleSpeech, whisperKit, whisperCLI
}

/// Names one speech model of one engine, e.g. `appleSpeech/en-US`.
public struct ModelID: Hashable, Codable, Sendable {
    public let engine: EngineKind
    public let name: String

    public init(engine: EngineKind, name: String) {
        self.engine = engine
        self.name = name
    }

    /// `engine/name`, for storage in the transcript store and preferences.
    public var storageKey: String { "\(engine.rawValue)/\(name)" }

    /// Parses a key made by `storageKey`; nil if it is not `engine/name`.
    public init?(storageKey: String) {
        guard let slash = storageKey.firstIndex(of: "/"),
              let engine = EngineKind(rawValue: String(storageKey[..<slash]))
        else { return nil }
        let name = String(storageKey[storageKey.index(after: slash)...])
        guard !name.isEmpty else { return nil }
        self.init(engine: engine, name: name)
    }

    /// `SpeechTranscriber`.
    public static let appleSpeech = ModelID(engine: .appleSpeech, name: "en-US")
    /// `DictationTranscriber` (Task 6).
    public static let appleDictation = ModelID(engine: .appleSpeech, name: "en-US-dictation")
}

public struct ModelDescriptor: Sendable, Identifiable {
    public let id: ModelID
    public let displayName: String
    public let detail: String

    public enum State: Sendable, Equatable {
        case ready, notDownloaded, downloading(Double), preparing, unavailable(String)
    }

    public var state: State
    public var bytesOnDisk: Int64?

    public init(id: ModelID, displayName: String, detail: String,
                state: State, bytesOnDisk: Int64? = nil) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.state = state
        self.bytesOnDisk = bytesOnDisk
    }
}
