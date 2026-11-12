import Foundation
import Observation
import SwiftData

/// Keeps every finished dictation as a `Transcript` in a SwiftData store,
/// `transcripts.store` in the given directory, on this Mac only (never
/// CloudKit). Every change is saved at once.
///
/// A store that cannot be opened (a damaged file, a schema it cannot
/// migrate) is moved aside with its `-wal` and `-shm` files, never deleted
/// (Review Focus 5), and a new, empty store starts in its place at once, so
/// every dictation is still kept (Ruling T11-3). `health` then says the old
/// history is unavailable and where its files are. Only when the files
/// cannot be moved aside, or no store can be started, is the store
/// unavailable: `container` is nil, `add` keeps nothing and `search` finds
/// nothing, and dictation goes on without history. Use from the main thread.
@MainActor @Observable
public final class TranscriptStore {
    public enum Health: Equatable {
        case ok
        /// The store could not be opened, so its files were moved aside and a
        /// new, empty store started, which works as usual. The words to show:
        /// the old history could not be opened, and where its files are.
        case recovered(String)
        /// There is no store: nothing is kept or found. The words to show
        /// where the transcripts would be.
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
    public convenience init(directory: URL, inMemory: Bool = false) {
        self.init(directory: directory, inMemory: inMemory, now: Date())
    }

    /// `now` names the files of a store that is moved aside; tests pass
    /// their own.
    init(directory: URL, inMemory: Bool = false, now: Date) {
        let opened = Self.open(directory.appendingPathComponent(Self.fileName), inMemory: inMemory, now: now)
        container = opened.container
        health = opened.health
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

    /// Makes the raw text the main text again, with the dictation's own model
    /// and time, undoing cleanup and any hand edit of the dictation's text. A
    /// main text from another model (a promoted re-transcription, or Danny's
    /// edit of one) is set aside as an alternate first, so it is not lost. A
    /// failed dictation has no raw text, so this never empties a text it got
    /// later from a re-transcription.
    public func revertToRaw(_ t: Transcript) {
        guard let context, !Self.isBlank(t.rawText) else { return }
        if t.modelKey != t.rawModelKey, !Self.isBlank(t.text) {
            let former = AlternateResult(formerMainOf: t)
            context.insert(former)
            t.alternates.append(former)
        }
        t.text = t.rawText
        t.modelKey = t.rawModelKey
        t.transcribeSeconds = t.rawTranscribeSeconds
        t.isEdited = false
        save("a revert to raw")
    }

    // MARK: - Alternates

    /// Keeps a re-transcription of the transcript's recording beside it. A
    /// newer result from the same model replaces that model's earlier
    /// re-transcription, never a main text set aside here
    /// (`AlternateResult.wasMain`), such as the pasted text.
    public func addAlternate(to t: Transcript, _ r: TranscriptionResult) {
        guard let context else { return }
        let key = r.model.storageKey
        if let earlier = t.alternates.first(where: { !$0.wasMain && $0.modelKey == key }) {
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
    /// time. The old main text is set aside as an alternate in its place, so
    /// nothing is lost (a hand-edited one under
    /// `AlternateResult.editedModelKey`); a failed dictation's empty one is
    /// dropped. A hand edit set aside earlier comes back as an edit:
    /// `isEdited`, labelled with the model whose text Danny edited, or, should
    /// that not be known, the dictation's own model and time. Any other
    /// result leaves the transcript not edited. `rawText`, `cleanedText` and
    /// the dictation's own model and time never change.
    public func promote(_ alt: AlternateResult, in t: Transcript) {
        guard let context else { return }
        guard let index = t.alternates.firstIndex(where: { $0.persistentModelID == alt.persistentModelID }) else {
            Log.info("[STORE] Not promoted: the result is not one of this transcript's alternates")
            return
        }
        let former = Self.isBlank(t.text) ? nil : AlternateResult(formerMainOf: t)
        t.text = alt.text
        if alt.modelKey == AlternateResult.editedModelKey {
            t.isEdited = true
            if let edited = alt.editedFromModelKey {
                t.modelKey = edited
                t.transcribeSeconds = alt.seconds
            } else {
                t.modelKey = t.rawModelKey
                t.transcribeSeconds = t.rawTranscribeSeconds
            }
        } else {
            t.isEdited = false
            t.modelKey = alt.modelKey
            t.transcribeSeconds = alt.seconds
        }
        t.alternates.remove(at: index)
        context.delete(alt)
        if let former {
            context.insert(former)
            t.alternates.append(former)
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

    /// Opens the store at `url`. A store that cannot be opened is moved
    /// aside, its files renamed with the suffix for `now`, and a new, empty
    /// store starts in its place at once (Ruling T11-3).
    private static func open(_ url: URL, inMemory: Bool, now: Date) -> (container: ModelContainer?, health: Health) {
        let failure: Error
        do {
            return (try openContainer(at: url, inMemory: inMemory), .ok)
        } catch {
            Log.info("[STORE] Could not open \(inMemory ? "the in-memory store" : url.path): \(error)")
            failure = error
        }
        guard !inMemory else { return (nil, .unavailable(unavailableMessage(failure))) }

        let moved: [URL]
        do {
            moved = try moveAside(url, suffix: brokenSuffix(at: now))
        } catch {
            Log.info("[STORE] Could not move \(url.lastPathComponent) aside: \(error)")
            return (nil, .unavailable("History is unavailable: the transcript store could not be opened or moved "
                                      + "aside (\(error.localizedDescription))."))
        }
        // Nothing was there to move aside, so a new store would fail the same way.
        guard !moved.isEmpty else { return (nil, .unavailable(unavailableMessage(failure))) }
        let folder = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        let names = ListFormatter.localizedString(byJoining: moved.map(\.lastPathComponent))
        let whereItIs = "Its files are in \(folder) as \(names)."
        do {
            let container = try openContainer(at: url, inMemory: false)
            Log.info("[STORE] Started a new \(url.lastPathComponent)")
            return (container, .recovered("Your earlier history could not be opened, so it was moved aside and a "
                                          + "new one started. " + whereItIs))
        } catch {
            Log.info("[STORE] Could not start a new \(url.lastPathComponent) either: \(error)")
            return (nil, .unavailable("History is unavailable: the transcript store could not be opened, and a new "
                                      + "one could not be started (\(error.localizedDescription)). " + whereItIs))
        }
    }

    /// Renames whichever of the store's files exist with `suffix`, the
    /// `-wal` and `-shm` journals first and the database last, and returns
    /// their new URLs. A failed rename stops the move and is thrown. The
    /// database then still has its name, so no new store is started beside a
    /// journal, and the next open fails again and moves the rest.
    private static func moveAside(_ url: URL, suffix: String) throws -> [URL] {
        var moved: [URL] = []
        for file in ["-wal", "-shm", ""].map({ URL(fileURLWithPath: url.path + $0) })
        where FileManager.default.fileExists(atPath: file.path) {
            let target = URL(fileURLWithPath: file.path + suffix)
            try FileManager.default.moveItem(at: file, to: target)
            Log.info("[STORE] Moved \(file.lastPathComponent) aside as \(target.lastPathComponent)")
            moved.append(target)
        }
        return moved
    }

    private static func unavailableMessage(_ error: Error) -> String {
        "History is unavailable: the transcript store could not be opened (\(error.localizedDescription))."
    }

    /// What the names of a store's files moved aside at `date` end with,
    /// e.g. `.broken-20261112-153012`.
    static func brokenSuffix(at date: Date) -> String {
        ".broken-" + brokenStamp.string(from: date)
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
