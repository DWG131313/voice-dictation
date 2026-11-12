import Foundation
import SwiftData

/// One finished dictation, as the transcript store keeps it.
///
/// `text` is the main text: what was pasted, until Danny edits it by hand
/// (`isEdited`) or makes another result the main one
/// (`TranscriptStore.promote`). Copy, Paste again and search use it.
/// `rawText` and `cleanedText` are the dictation's own model output and its
/// cleanup; no edit changes them, so "Revert to raw" always works.
@Model
public final class Transcript {
    /// The dictation's id (`DictationOutcome.id`).
    @Attribute(.unique) public var id: UUID
    /// When the recording ended.
    public var date: Date
    /// The main text. Empty for a failed dictation.
    public var text: String
    /// The model's text before cleanup. Empty for a failed dictation.
    public var rawText: String
    /// What cleanup made of `rawText`, when it ran and was accepted.
    public var cleanedText: String?
    /// The app that was frontmost when the dictation finished.
    public var appName: String?
    /// The model behind `text`, as `ModelID.storageKey`; for a hand edit,
    /// the model whose text Danny edited. Always a real model, never
    /// `AlternateResult.editedModelKey`.
    public var modelKey: String
    /// The dictation's own model, the one behind `rawText`, as
    /// `ModelID.storageKey`. Set when the transcript is made; never changes.
    public private(set) var rawModelKey: String
    /// The recording's length; 0 when unknown, as for imported history.
    public var recordingSeconds: Double
    /// The model's time on the clip, for `text`.
    public var transcribeSeconds: Double
    /// The dictation's own model's time on the clip, for `rawText`. Set when
    /// the transcript is made; never changes.
    public private(set) var rawTranscribeSeconds: Double
    public var cleanupSeconds: Double?
    /// `DictationOutcome.Status.rawValue`; read it as `status`.
    public var statusRaw: String
    /// Why the dictation failed, for a failed one.
    public var failure: String?
    public var pinned: Bool
    /// True while `text` is one Danny changed by hand.
    public var isEdited: Bool
    /// The kept recording's file name in the audio archive (Task 12).
    public var audioFileName: String?
    /// Other texts for the same recording: the latest re-transcription with
    /// each model, and main texts that `promote` or `revertToRaw` replaced
    /// (`AlternateResult.wasMain`). Unordered; sort by `date` to show them.
    @Relationship(deleteRule: .cascade) public var alternates: [AlternateResult]

    /// `modelKey` and `transcribeSeconds` are the dictation's own, so they
    /// are also kept as `rawModelKey` and `rawTranscribeSeconds`.
    public init(id: UUID = UUID(), date: Date, text: String, rawText: String, cleanedText: String? = nil,
                appName: String? = nil, modelKey: String, recordingSeconds: Double, transcribeSeconds: Double,
                cleanupSeconds: Double? = nil, statusRaw: String, failure: String? = nil, pinned: Bool = false,
                isEdited: Bool = false, audioFileName: String? = nil, alternates: [AlternateResult] = []) {
        self.id = id
        self.date = date
        self.text = text
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.appName = appName
        self.modelKey = modelKey
        self.rawModelKey = modelKey
        self.recordingSeconds = recordingSeconds
        self.transcribeSeconds = transcribeSeconds
        self.rawTranscribeSeconds = transcribeSeconds
        self.cleanupSeconds = cleanupSeconds
        self.statusRaw = statusRaw
        self.failure = failure
        self.pinned = pinned
        self.isEdited = isEdited
        self.audioFileName = audioFileName
        self.alternates = alternates
    }
}

extension Transcript {
    /// The transcript of a finished dictation, before anyone has changed it.
    convenience init(_ outcome: DictationOutcome) {
        self.init(id: outcome.id, date: outcome.date, text: outcome.text, rawText: outcome.rawText,
                  cleanedText: outcome.cleanedText, appName: outcome.appName, modelKey: outcome.model.storageKey,
                  recordingSeconds: outcome.clip?.duration ?? 0, transcribeSeconds: outcome.transcribeSeconds,
                  cleanupSeconds: outcome.cleanupSeconds, statusRaw: outcome.status.rawValue, failure: outcome.failure)
    }

    /// Pasted, Copied or Failed. A value this version does not know reads
    /// as failed.
    public var status: DictationOutcome.Status {
        DictationOutcome.Status(rawValue: statusRaw) ?? .failed
    }
}

/// Another text for a transcript's recording: a re-transcription with
/// another model, or a main text that `TranscriptStore.promote` or
/// `revertToRaw` replaced.
@Model
public final class AlternateResult {
    /// The model that produced `text`, as `ModelID.storageKey`, or
    /// `AlternateResult.editedModelKey` for a hand-edited text.
    public var modelKey: String
    public var text: String
    /// The model's time on the clip.
    public var seconds: Double
    /// When it became one of the transcript's alternates.
    public var date: Date
    /// True for a main text that `promote` or `revertToRaw` set aside here,
    /// such as the pasted text; false for a re-transcription. A newer
    /// re-transcription with the same model replaces an earlier one, but
    /// never a text that was the main text.
    public var wasMain: Bool
    /// For a hand-edited text, the model whose text Danny edited, as
    /// `ModelID.storageKey`; nil otherwise.
    public var editedFromModelKey: String?

    public init(modelKey: String, text: String, seconds: Double, date: Date = Date(),
                wasMain: Bool = false, editedFromModelKey: String? = nil) {
        self.modelKey = modelKey
        self.text = text
        self.seconds = seconds
        self.date = date
        self.wasMain = wasMain
        self.editedFromModelKey = editedFromModelKey
    }
}

extension AlternateResult {
    /// The `modelKey` of a hand-edited main text that `promote` or
    /// `revertToRaw` set aside.
    public static let editedModelKey = "edited"

    /// The transcript's main text, set aside when another text takes its
    /// place. A hand edit is kept under `editedModelKey`, with the model
    /// whose text Danny edited.
    convenience init(formerMainOf t: Transcript) {
        self.init(modelKey: t.isEdited ? Self.editedModelKey : t.modelKey, text: t.text,
                  seconds: t.transcribeSeconds, wasMain: true, editedFromModelKey: t.isEdited ? t.modelKey : nil)
    }
}
