import Foundation
import Observation
import SwiftData

/// Keeps every finished dictation as a `Transcript` in a SwiftData store,
/// `transcripts.store` in the given directory, on this Mac only (never
/// CloudKit). Every change is saved at once.
///
/// A store that cannot be opened (a damaged file, a schema it cannot
/// migrate) is moved aside with its `-wal` and `-shm` files, never deleted
/// (Review Focus 5). `health` then says so, `container` is nil, `add` keeps
/// nothing and `search` finds nothing: dictation goes on without history,
/// and the next launch starts a new store. Use from the main thread.
@MainActor @Observable
public final class TranscriptStore {
    public enum Health: Equatable {
        case ok
        /// The words to show where the transcripts would be.
        case unavailable(String)
    }

    /// Which transcripts `search` looks at.
    public enum Scope: Sendable {
        case all
        /// Since the start of today.
        case today
        case pinned
    }

    static let fileName = "transcripts.store"

    public private(set) var health: Health
    /// Nil when the store is unavailable.
    public let container: ModelContainer?

    /// Opens, or starts, `transcripts.store` in `directory`, creating the
    /// directory if needed. In memory, nothing is read or written there.
    public init(directory: URL, inMemory: Bool = false) {
        let url = directory.appendingPathComponent(Self.fileName)
        do {
            container = try Self.openContainer(at: url, inMemory: inMemory)
            health = .ok
        } catch {
            Log.info("[STORE] Could not open \(inMemory ? "the in-memory store" : url.path): \(error)")
            container = nil
            health = .unavailable(inMemory ? Self.unavailableMessage(error) : Self.setAside(url, after: error))
        }
    }

    // MARK: - Adding and finding

    /// Keeps a finished dictation. Returns its transcript, or nil when the
    /// store is unavailable or the transcript could not be saved.
    @discardableResult
    public func add(_ outcome: DictationOutcome) -> Transcript? {
        guard let context else { return nil }
        let transcript = Transcript(outcome)
        context.insert(transcript)
        return save("the transcript of \(outcome.id)") ? transcript : nil
    }

    /// The transcripts in `scope` whose main text contains `query`, ignoring
    /// case (and accents), newest first. An empty query matches every one.
    public func search(_ query: String, scope: Scope) -> [Transcript] {
        guard let context else { return [] }
        let since = scope == .today ? Calendar.current.startOfDay(for: Date()) : Date.distantPast
        let pinnedOnly = scope == .pinned
        let anyText = query.isEmpty
        let descriptor = FetchDescriptor<Transcript>(
            predicate: #Predicate { transcript in
                transcript.date >= since
                    && (!pinnedOnly || transcript.pinned)
                    && (anyText || transcript.text.localizedStandardContains(query))
            },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            Log.info("[STORE] Could not search the transcripts: \(error)")
            return []
        }
    }

    /// The newest transcript that has text, so a failed dictation is
    /// skipped: what Paste last transcript pastes (Task 23).
    public var latest: Transcript? {
        guard let context else { return nil }
        var descriptor = FetchDescriptor<Transcript>(
            predicate: #Predicate { $0.text != "" },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            Log.info("[STORE] Could not find the latest transcript: \(error)")
            return nil
        }
    }

    // MARK: - Changing a transcript

    public func setPinned(_ t: Transcript, _ pinned: Bool) {
        guard t.pinned != pinned else { return }
        t.pinned = pinned
        save("a pin")
    }

    /// Deletes the transcript and its alternates.
    public func delete(_ t: Transcript) {
        guard let context else { return }
        context.delete(t)
        save("a deletion")
    }

    /// A hand edit: makes `newText` the main text and marks the transcript
    /// edited. Empty or whitespace-only text, or the same text, changes
    /// nothing. `rawText` and `cleanedText` are never touched.
    public func updateText(_ t: Transcript, _ newText: String) {
        guard !Self.isBlank(newText), newText != t.text else { return }
        t.text = newText
        t.isEdited = true
        save("an edit")
    }

    /// Makes the raw text the main text again, undoing cleanup and any hand
    /// edit. A failed dictation has no raw text, so this never empties a
    /// text it got later from a re-transcription.
    public func revertToRaw(_ t: Transcript) {
        guard !Self.isBlank(t.rawText) else { return }
        t.text = t.rawText
        t.isEdited = false
        save("a revert to raw")
    }

    // MARK: - Alternates

    /// Keeps a re-transcription of the transcript's recording beside it. A
    /// newer result from the same model replaces the earlier one.
    public func addAlternate(to t: Transcript, _ r: TranscriptionResult) {
        guard let context else { return }
        let key = r.model.storageKey
        if let earlier = t.alternates.first(where: { $0.modelKey == key }) {
            earlier.text = r.text
            earlier.seconds = r.elapsed
            earlier.date = Date()
        } else {
            let alternate = AlternateResult(modelKey: key, text: r.text, seconds: r.elapsed)
            context.insert(alternate)
            t.alternates.append(alternate)
        }
        save("an alternate")
    }

    /// "Use this one": makes the alternate the main text, with its model and
    /// time. The old main text becomes an alternate in its place, so nothing
    /// is lost; a hand-edited one is kept as `AlternateResult.editedModelKey`,
    /// and a failed dictation's empty one is dropped. The transcript is no
    /// longer edited; `rawText` and `cleanedText` stay the dictation's own.
    public func promote(_ alt: AlternateResult, in t: Transcript) {
        guard let context else { return }
        guard let index = t.alternates.firstIndex(where: { $0.persistentModelID == alt.persistentModelID }) else {
            Log.info("[STORE] Not promoted: the result is not one of this transcript's alternates")
            return
        }
        let replaced = (modelKey: t.isEdited ? AlternateResult.editedModelKey : t.modelKey,
                        text: t.text, seconds: t.transcribeSeconds)
        t.text = alt.text
        t.modelKey = alt.modelKey
        t.transcribeSeconds = alt.seconds
        t.isEdited = false
        if Self.isBlank(replaced.text) {
            t.alternates.remove(at: index)
            context.delete(alt)
        } else {
            alt.modelKey = replaced.modelKey
            alt.text = replaced.text
            alt.seconds = replaced.seconds
            alt.date = Date()
        }
        save("a promoted alternate")
    }

    // MARK: - Opening

    private var context: ModelContext? { container?.mainContext }

    private static func openContainer(at url: URL, inMemory: Bool) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            configuration = ModelConfiguration(url: url, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: Transcript.self, AlternateResult.self, configurations: configuration)
    }

    /// Renames the store's files (the database and its `-wal` and `-shm`)
    /// with one `.broken-<date-time>` suffix, so the next store made at `url`
    /// starts afresh and never meets a leftover journal. Returns the words
    /// `health` shows.
    private static func setAside(_ url: URL, after error: Error) -> String {
        let suffix = ".broken-" + brokenStamp.string(from: Date())
        let files = ["", "-wal", "-shm"]
            .map { URL(fileURLWithPath: url.path + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return unavailableMessage(error) }
        do {
            for file in files {
                let target = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + suffix)
                try FileManager.default.moveItem(at: file, to: target)
            }
        } catch let moveError {
            Log.info("[STORE] Could not move \(url.lastPathComponent) aside: \(moveError)")
            return "History is unavailable: the transcript store could not be opened or moved aside "
                + "(\(moveError.localizedDescription))."
        }
        Log.info("[STORE] Moved \(files.map(\.lastPathComponent).joined(separator: ", ")) aside with the suffix \(suffix)")
        return "History is unavailable: the transcript store could not be opened. It was moved aside as "
            + "\(url.lastPathComponent)\(suffix), and a new one starts at the next launch."
    }

    private static func unavailableMessage(_ error: Error) -> String {
        "History is unavailable: the transcript store could not be opened (\(error.localizedDescription))."
    }

    /// Local date and time, e.g. `20261112-153012`.
    private static let brokenStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    // MARK: - Saving

    /// Saves the change just made. A failed save is logged and undone, so the
    /// transcripts in memory stay those on disk.
    @discardableResult
    private func save(_ change: String) -> Bool {
        guard let context else { return false }
        do {
            try context.save()
            return true
        } catch {
            Log.info("[STORE] Could not save \(change): \(error)")
            context.rollback()
            return false
        }
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
