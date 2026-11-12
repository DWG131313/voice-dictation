import SwiftData
import XCTest
@testable import VoiceDictationLib

/// The transcript store, in memory or in a temporary folder of its own
/// (Ruling T11-2): never the real `transcripts.store`.
final class TranscriptStoreTests: XCTestCase {
    private let clip = AudioClip(samples: [Float](repeating: 0.1, count: 24_000))
    private let base = Date(timeIntervalSince1970: 1_762_900_000)
    private let whisperBase = ModelID(engine: .whisperKit, name: "base.en")
    private let whisperSmall = ModelID(engine: .whisperKit, name: "small.en")
    /// Folders made by `makeDirectory()`, removed after each test.
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    // MARK: - Adding and searching

    @MainActor
    func testAddAndSearchRoundTrip() throws {
        let store = memoryStore()
        let pasted = DictationOutcome(
            date: base, clip: clip, rawText: "um hello there", cleanedText: "Hello there.", text: "Hello there.",
            model: whisperBase, transcribeSeconds: 0.42, cleanupSeconds: 0.3, appName: "Notes", status: .copied
        )
        let failed = DictationOutcome(
            date: base.addingTimeInterval(60), clip: nil, rawText: "", text: "", model: .appleSpeech,
            transcribeSeconds: 0, appName: nil, status: .failed, failure: DictationPipeline.skippedFailure
        )

        let added = try XCTUnwrap(store.add(pasted))
        XCTAssertNotNil(store.add(failed))

        let found = store.search("", scope: .all)
        XCTAssertEqual(found.map(\.id), [failed.id, pasted.id], "newest first")
        let transcript = found[1]
        XCTAssertTrue(transcript === added)
        XCTAssertEqual(transcript.date, base)
        XCTAssertEqual(transcript.text, "Hello there.")
        XCTAssertEqual(transcript.rawText, "um hello there")
        XCTAssertEqual(transcript.cleanedText, "Hello there.")
        XCTAssertEqual(transcript.appName, "Notes")
        XCTAssertEqual(transcript.modelKey, "whisperKit/base.en")
        XCTAssertEqual(transcript.recordingSeconds, 1.5, "from the clip")
        XCTAssertEqual(transcript.transcribeSeconds, 0.42)
        XCTAssertEqual(transcript.cleanupSeconds, 0.3)
        XCTAssertEqual(transcript.statusRaw, "copied")
        XCTAssertEqual(transcript.status, .copied)
        XCTAssertNil(transcript.failure)
        XCTAssertFalse(transcript.pinned)
        XCTAssertFalse(transcript.isEdited)
        XCTAssertNil(transcript.audioFileName)
        XCTAssertEqual(transcript.alternates.count, 0)

        let failure = found[0]
        XCTAssertEqual(failure.status, .failed)
        XCTAssertEqual(failure.failure, DictationPipeline.skippedFailure)
        XCTAssertEqual(failure.text, "")
        XCTAssertEqual(failure.modelKey, "appleSpeech/en-US")
        XCTAssertEqual(failure.recordingSeconds, 0, "no clip")
        XCTAssertNil(failure.appName)
    }

    @MainActor
    func testSearchIsCaseInsensitiveSubstring() {
        let store = memoryStore()
        store.add(outcome("Set up Tailscale on the Mac mini", at: base))
        store.add(outcome("Ship the build", at: base.addingTimeInterval(60)))
        store.add(outcome("TAILSCALE is down again", at: base.addingTimeInterval(120)))

        XCTAssertEqual(store.search("tailscale", scope: .all).map(\.text),
                       ["TAILSCALE is down again", "Set up Tailscale on the Mac mini"])
        XCTAssertEqual(store.search("MAC MIN", scope: .all).map(\.text), ["Set up Tailscale on the Mac mini"])
        XCTAssertEqual(store.search("p the b", scope: .all).map(\.text), ["Ship the build"])
        XCTAssertEqual(store.search("vercel", scope: .all), [])
        XCTAssertEqual(store.search("", scope: .all).count, 3, "an empty query matches everything")
    }

    @MainActor
    func testTodayScope() {
        let store = memoryStore()
        let startOfToday = Calendar.current.startOfDay(for: Date())
        store.add(outcome("Late last night", at: startOfToday.addingTimeInterval(-1)))
        store.add(outcome("First thing today", at: startOfToday))
        store.add(outcome("Just now", at: Date()))

        XCTAssertEqual(store.search("", scope: .today).map(\.text), ["Just now", "First thing today"])
        XCTAssertEqual(store.search("FIRST", scope: .today).map(\.text), ["First thing today"])
        XCTAssertEqual(store.search("night", scope: .today), [])
        XCTAssertEqual(store.search("", scope: .all).count, 3)
    }

    @MainActor
    func testPinnedScope() throws {
        let store = memoryStore()
        let keep = try XCTUnwrap(store.add(outcome("Pin me", at: base)))
        store.add(outcome("Leave me", at: base.addingTimeInterval(60)))

        store.setPinned(keep, true)

        XCTAssertTrue(keep.pinned)
        XCTAssertEqual(store.search("", scope: .pinned).map(\.text), ["Pin me"])
        XCTAssertEqual(store.search("pin", scope: .pinned).map(\.text), ["Pin me"])
        XCTAssertEqual(store.search("leave", scope: .pinned), [])

        store.setPinned(keep, false)

        XCTAssertEqual(store.search("", scope: .pinned), [])
        XCTAssertEqual(store.search("", scope: .all).count, 2)
    }

    /// What Paste last transcript pastes (Task 23): the newest transcript by
    /// date, skipping failed ones, which have no text.
    @MainActor
    func testLatestIsTheNewestTranscriptWithText() {
        let store = memoryStore()
        XCTAssertNil(store.latest)

        store.add(outcome("Newer", at: base.addingTimeInterval(60)))
        store.add(outcome("Older", at: base))
        XCTAssertEqual(store.latest?.text, "Newer", "by date, not by when it was added")

        store.add(failedOutcome(at: base.addingTimeInterval(120)))
        XCTAssertEqual(store.latest?.text, "Newer")
    }

    // MARK: - Edits

    @MainActor
    func testUpdateTextMarksEditedAndKeepsRawAndCleaned() throws {
        let store = memoryStore()
        let transcript = try XCTUnwrap(store.add(outcome("Hello there.", rawText: "um hello there", cleanedText: "Hello there.")))

        store.updateText(transcript, "Hello there.")
        XCTAssertFalse(transcript.isEdited, "the same text is not an edit")

        store.updateText(transcript, "Hello there, Danny.")

        XCTAssertEqual(transcript.text, "Hello there, Danny.")
        XCTAssertTrue(transcript.isEdited)
        XCTAssertEqual(transcript.rawText, "um hello there")
        XCTAssertEqual(transcript.cleanedText, "Hello there.")
    }

    @MainActor
    func testUpdateTextIgnoresEmpty() throws {
        let store = memoryStore()
        let transcript = try XCTUnwrap(store.add(outcome("Hello there.")))

        store.updateText(transcript, "")
        store.updateText(transcript, "  \n\t ")

        XCTAssertEqual(transcript.text, "Hello there.")
        XCTAssertFalse(transcript.isEdited)

        store.updateText(transcript, "Hello again.")
        store.updateText(transcript, " ")

        XCTAssertEqual(transcript.text, "Hello again.")
        XCTAssertTrue(transcript.isEdited)
    }

    @MainActor
    func testSearchFindsEditedText() throws {
        let store = memoryStore()
        let transcript = try XCTUnwrap(store.add(outcome("Meet at the cafe")))

        store.updateText(transcript, "Meet at the Vercel office")

        XCTAssertEqual(store.search("vercel", scope: .all).map(\.id), [transcript.id])
        XCTAssertEqual(store.search("cafe", scope: .all), [], "search reads the main text only")
    }

    @MainActor
    func testRevertToRaw() throws {
        let store = memoryStore()
        let transcript = try XCTUnwrap(store.add(outcome("Hello there.", rawText: "um hello there", cleanedText: "Hello there.")))
        store.updateText(transcript, "Hello there, Danny.")

        store.revertToRaw(transcript)

        XCTAssertEqual(transcript.text, "um hello there")
        XCTAssertFalse(transcript.isEdited)
        XCTAssertEqual(transcript.rawText, "um hello there")
        XCTAssertEqual(transcript.cleanedText, "Hello there.")
    }

    /// A failed dictation has no raw text, so reverting cannot empty a text
    /// it got later from a re-transcription.
    @MainActor
    func testRevertToRawKeepsTextWhenThereIsNoRawText() throws {
        let store = memoryStore()
        let transcript = try XCTUnwrap(store.add(failedOutcome()))
        store.addAlternate(to: transcript, TranscriptionResult(text: "Hello there.", model: .appleSpeech, elapsed: 0.3))
        store.promote(try XCTUnwrap(transcript.alternates.first), in: transcript)
        store.updateText(transcript, "Hello there, Danny.")

        store.revertToRaw(transcript)

        XCTAssertEqual(transcript.text, "Hello there, Danny.")
        XCTAssertTrue(transcript.isEdited)
    }

    // MARK: - Alternates

    @MainActor
    func testPromoteAlternateSwapsText() throws {
        let store = memoryStore()
        let transcript = try XCTUnwrap(store.add(outcome("Hello there.", model: .appleSpeech, transcribeSeconds: 0.2)))
        store.addAlternate(to: transcript, TranscriptionResult(text: "Hello, there.", model: whisperBase, elapsed: 0.5))
        let alternate = try XCTUnwrap(transcript.alternates.first)

        store.promote(alternate, in: transcript)

        XCTAssertEqual(transcript.text, "Hello, there.")
        XCTAssertEqual(transcript.modelKey, "whisperKit/base.en")
        XCTAssertEqual(transcript.transcribeSeconds, 0.5)
        XCTAssertEqual(transcript.rawText, "Hello there.", "the dictation's own raw text stays")
        XCTAssertEqual(transcript.alternates.count, 1)
        let previous = try XCTUnwrap(transcript.alternates.first)
        XCTAssertEqual(previous.text, "Hello there.", "the old main text is kept")
        XCTAssertEqual(previous.modelKey, "appleSpeech/en-US")
        XCTAssertEqual(previous.seconds, 0.2)

        // A hand edit that another result replaces is kept as "edited".
        store.updateText(transcript, "Hello, there, Danny.")
        store.promote(previous, in: transcript)

        XCTAssertEqual(transcript.text, "Hello there.")
        XCTAssertEqual(transcript.modelKey, "appleSpeech/en-US")
        XCTAssertFalse(transcript.isEdited)
        XCTAssertEqual(transcript.alternates.map(\.modelKey), ["edited"])
        XCTAssertEqual(transcript.alternates.map(\.text), ["Hello, there, Danny."])
    }

    /// A failed dictation's empty text is not worth keeping as an alternate.
    @MainActor
    func testPromotingIntoAFailedTranscriptKeepsNoEmptyAlternate() throws {
        let store = memoryStore()
        let transcript = try XCTUnwrap(store.add(failedOutcome()))
        store.addAlternate(to: transcript, TranscriptionResult(text: "Hello there.", model: .appleSpeech, elapsed: 0.3))

        store.promote(try XCTUnwrap(transcript.alternates.first), in: transcript)

        XCTAssertEqual(transcript.text, "Hello there.")
        XCTAssertEqual(transcript.transcribeSeconds, 0.3)
        XCTAssertEqual(transcript.alternates.count, 0)
        XCTAssertEqual(try alternatesStored(in: store), 0)
    }

    /// Re-transcribing with the same model again replaces that model's
    /// result instead of adding a second one (Task 19).
    @MainActor
    func testAddAlternateReplacesTheSameModelsEarlierResult() throws {
        let store = memoryStore()
        let transcript = try XCTUnwrap(store.add(outcome("Hello there.")))

        store.addAlternate(to: transcript, TranscriptionResult(text: "First try.", model: whisperBase, elapsed: 0.5))
        store.addAlternate(to: transcript, TranscriptionResult(text: "Small.", model: whisperSmall, elapsed: 0.9))
        store.addAlternate(to: transcript, TranscriptionResult(text: "Second try.", model: whisperBase, elapsed: 0.4))

        let byModel = Dictionary(uniqueKeysWithValues: transcript.alternates.map { ($0.modelKey, ($0.text, $0.seconds)) })
        XCTAssertEqual(byModel.count, 2)
        XCTAssertEqual(byModel["whisperKit/base.en"]?.0, "Second try.")
        XCTAssertEqual(byModel["whisperKit/base.en"]?.1, 0.4)
        XCTAssertEqual(byModel["whisperKit/small.en"]?.0, "Small.")
        XCTAssertEqual(try alternatesStored(in: store), 2)
    }

    @MainActor
    func testDeleteRemovesTheTranscriptAndItsAlternates() throws {
        let store = memoryStore()
        let gone = try XCTUnwrap(store.add(outcome("Delete me", at: base)))
        store.addAlternate(to: gone, TranscriptionResult(text: "Delete me.", model: whisperBase, elapsed: 0.5))
        store.addAlternate(to: gone, TranscriptionResult(text: "Delete me!", model: whisperSmall, elapsed: 0.9))
        let kept = try XCTUnwrap(store.add(outcome("Keep me", at: base.addingTimeInterval(60))))
        store.addAlternate(to: kept, TranscriptionResult(text: "Keep me.", model: whisperBase, elapsed: 0.5))

        store.delete(gone)

        XCTAssertEqual(store.search("", scope: .all).map(\.text), ["Keep me"])
        XCTAssertEqual(try alternatesStored(in: store), 1, "the deleted transcript's alternates go with it")
    }

    // MARK: - On disk

    /// Every change is saved at once, so a store opened again on the same
    /// file (the next launch) sees it.
    @MainActor
    func testChangesAreSavedToDisk() throws {
        let directory = try makeDirectory().appendingPathComponent("VoiceDictation", isDirectory: true)
        do {
            let store = TranscriptStore(directory: directory)
            XCTAssertEqual(store.health, .ok)
            let context = try XCTUnwrap(store.container).mainContext
            func assertSaved(_ change: String, line: UInt = #line) {
                XCTAssertFalse(context.hasChanges, "\(change) was left unsaved", line: line)
            }
            let edited = try XCTUnwrap(store.add(outcome("Edited.", at: base, rawText: "edited")))
            assertSaved("add")
            store.setPinned(edited, true)
            assertSaved("setPinned")
            store.updateText(edited, "Edited by hand.")
            assertSaved("updateText")
            store.addAlternate(to: edited, TranscriptionResult(text: "Edited!", model: whisperBase, elapsed: 0.5))
            assertSaved("addAlternate")
            let reverted = try XCTUnwrap(store.add(outcome("Reverted.", at: base.addingTimeInterval(60), rawText: "reverted")))
            store.updateText(reverted, "Reverted by hand.")
            store.revertToRaw(reverted)
            assertSaved("revertToRaw")
            let promoted = try XCTUnwrap(store.add(outcome("Promoted.", at: base.addingTimeInterval(120))))
            store.addAlternate(to: promoted, TranscriptionResult(text: "Promoted!", model: whisperSmall, elapsed: 0.9))
            store.promote(try XCTUnwrap(promoted.alternates.first), in: promoted)
            assertSaved("promote")
            store.delete(try XCTUnwrap(store.add(outcome("Deleted.", at: base.addingTimeInterval(180)))))
            assertSaved("delete")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcripts.store").path))

        let reopened = TranscriptStore(directory: directory)

        let transcripts = reopened.search("", scope: .all)
        XCTAssertEqual(transcripts.map(\.rawText), ["Promoted.", "reverted", "edited"])
        let promoted = transcripts[0], reverted = transcripts[1], edited = transcripts[2]
        XCTAssertEqual(edited.text, "Edited by hand.")
        XCTAssertTrue(edited.isEdited)
        XCTAssertTrue(edited.pinned)
        XCTAssertEqual(edited.alternates.map(\.text), ["Edited!"])
        XCTAssertEqual(reverted.text, "reverted")
        XCTAssertFalse(reverted.isEdited)
        XCTAssertEqual(promoted.text, "Promoted!")
        XCTAssertEqual(promoted.modelKey, "whisperKit/small.en")
        XCTAssertEqual(promoted.alternates.map(\.text), ["Promoted."])
    }

    /// Review Focus 5: a store that cannot be opened is moved aside with its
    /// `-wal` and `-shm` files, history is unavailable, and nothing crashes.
    @MainActor
    func testCorruptStoreIsMovedAsideAndHealthUnavailable() throws {
        let directory = try makeDirectory()
        let names = ["transcripts.store", "transcripts.store-wal", "transcripts.store-shm"]
        let garbage = Data("This is not a SQLite database.".utf8)
        for name in names {
            try garbage.write(to: directory.appendingPathComponent(name))
        }

        let store = TranscriptStore(directory: directory)

        guard case .unavailable(let message) = store.health else {
            return XCTFail("health is \(store.health)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(store.container)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in names {
            XCTAssertFalse(left.contains(name), "\(name) is still there: \(left)")
        }
        var suffixes: Set<String> = []
        for name in names {
            let moved = try XCTUnwrap(left.first { $0.hasPrefix(name + ".broken-") }, "\(name) not moved aside: \(left)")
            suffixes.insert(String(moved.dropFirst(name.count)))
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(moved)), garbage, "moved, not rewritten")
        }
        XCTAssertEqual(suffixes.count, 1, "one suffix for all three: \(left)")
        XCTAssertEqual(left.count, 3, "nothing else left behind: \(left)")
        XCTAssertNil(store.add(outcome("Hello there.")))
        XCTAssertEqual(store.search("", scope: .all), [])
        XCTAssertNil(store.latest)

        // The next launch starts a new store, which never meets the old journal.
        let next = TranscriptStore(directory: directory)
        XCTAssertEqual(next.health, .ok)
        XCTAssertNotNil(next.add(outcome("Hello again.")))
        XCTAssertEqual(next.search("", scope: .all).map(\.text), ["Hello again."])
    }

    // MARK: - Helpers

    @MainActor
    private func memoryStore() -> TranscriptStore {
        // Never created: an in-memory store writes nothing.
        let unused = FileManager.default.temporaryDirectory.appendingPathComponent("vd-unused-\(UUID().uuidString)")
        let store = TranscriptStore(directory: unused, inMemory: true)
        XCTAssertEqual(store.health, .ok)
        return store
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vd-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    @MainActor
    private func alternatesStored(in store: TranscriptStore) throws -> Int {
        try XCTUnwrap(store.container).mainContext.fetchCount(FetchDescriptor<AlternateResult>())
    }

    private func outcome(_ text: String, at date: Date = Date(), model: ModelID = .appleSpeech,
                         rawText: String? = nil, cleanedText: String? = nil,
                         transcribeSeconds: Double = 0.2) -> DictationOutcome {
        DictationOutcome(date: date, clip: clip, rawText: rawText ?? text, cleanedText: cleanedText, text: text,
                         model: model, transcribeSeconds: transcribeSeconds, appName: "TextEdit", status: .pasted)
    }

    private func failedOutcome(at date: Date = Date()) -> DictationOutcome {
        DictationOutcome(date: date, clip: clip, rawText: "", text: "", model: .appleSpeech, transcribeSeconds: 0,
                         appName: "TextEdit", status: .failed, failure: "Apple Speech language files are not installed")
    }
}
