import Foundation

/// What the app is doing, as the menu bar and the indicator show it.
public enum DictationState: Equatable, Sendable {
    case idle, recording(since: Date), transcribing, cleaning
    /// A model is downloading or loading for dictation; the model's name.
    case preparingModel(String)
    /// Dictation cannot work without this permission ("Accessibility", "Microphone").
    case needsPermission(String)
    /// Something just failed; shown for a few seconds, then the true state returns.
    case error(String)
}

/// One finished dictation. A cancelled dictation produces none; every other
/// one, including one that failed or was skipped, produces exactly one.
public struct DictationOutcome: Sendable {
    public enum Status: String, Codable, Sendable {
        /// Pasted into the frontmost app.
        case pasted
        /// Left on the clipboard because it could not be pasted.
        case copied
        /// Nothing to paste: the model failed, or the dictation was skipped.
        case failed
    }

    public let id: UUID
    /// When the recording ended.
    public let date: Date
    /// The recording, kept so a failed dictation can be transcribed again.
    public let clip: AudioClip?
    /// The model's text; empty for a failure.
    public let rawText: String
    public let cleanedText: String?
    /// What was pasted (or left on the clipboard); empty for a failure.
    public var text: String
    /// The model that transcribed it, or for a failure, the model selected then.
    public let model: ModelID
    /// The model's time on the clip, without waiting in line or loading.
    public let transcribeSeconds: Double
    public let cleanupSeconds: Double?
    /// The app that was frontmost when the dictation finished.
    public let appName: String?
    public let status: Status
    /// Why it failed, for `.failed`.
    public let failure: String?

    public init(id: UUID = UUID(), date: Date, clip: AudioClip?, rawText: String, cleanedText: String? = nil,
                text: String, model: ModelID, transcribeSeconds: Double, cleanupSeconds: Double? = nil,
                appName: String?, status: Status, failure: String? = nil) {
        self.id = id
        self.date = date
        self.clip = clip
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.text = text
        self.model = model
        self.transcribeSeconds = transcribeSeconds
        self.cleanupSeconds = cleanupSeconds
        self.appName = appName
        self.status = status
        self.failure = failure
    }
}
