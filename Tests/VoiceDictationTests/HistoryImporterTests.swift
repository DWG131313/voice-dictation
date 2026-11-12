import XCTest
@testable import VoiceDictationLib

/// The one-time import of the old app's `history.json`. Each test writes its
/// own file to a temporary folder and keeps its flag in memory (Rulings
/// T11-1, T11-2): never Danny's real `history.json`, store or preferences.
final class HistoryImporterTests: XCTestCase {
    private let preferences = MemoryPreferenceStore()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vd-history-\(UUID().uuidString)", isDirectory: true)
    private let models = ["base.en", "small.en", "tiny.en"]

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @MainActor
    func testImportsOnceAndLeavesFileUntouched() throws {
        let entries = makeEntries(20)
        let file = try writeHistory(entries)
        let bytes = try Data(contentsOf: file)
        let store = memoryStore()

        XCTAssertEqual(HistoryImporter.importIfNeeded(from: file, into: store, preferences: preferences), 20)

        let transcripts = store.search("", scope: .all)
        XCTAssertEqual(transcripts.count, 20)
        for entry in entries {
            let transcript = try XCTUnwrap(transcripts.first { $0.text == entry.text }, "\(entry.text) missing")
            XCTAssertEqual(transcript.status, .pasted)
            XCTAssertEqual(transcript.modelKey, "whisperCLI/\(entry.modelId)")
            XCTAssertEqual(transcript.date, entry.timestamp)
            XCTAssertEqual(transcript.rawText, entry.text)
            XCTAssertNil(transcript.cleanedText)
            XCTAssertFalse(transcript.isEdited)
        }
        XCTAssertEqual(transcripts.first?.text, "Entry 19", "newest first, as in the old menu")

        XCTAssertEqual(HistoryImporter.importIfNeeded(from: file, into: store, preferences: preferences), 0)
        XCTAssertEqual(store.search("", scope: .all).count, 20)
        XCTAssertEqual(HistoryImporter.importIfNeeded(from: file, into: memoryStore(), preferences: preferences), 0,
                       "marked done: not even an empty store gets them again")
        XCTAssertEqual(try Data(contentsOf: file), bytes, "history.json is left as it was")
    }

    /// The flag lives in the defaults of the binary that imported, and the
    /// bare dev binary and the app bundle have different ones (Task 13).
    /// Entries already in the store are not imported a second time.
    @MainActor
    func testEntriesAlreadyInTheStoreAreNotImportedAgain() throws {
        let file = try writeHistory(makeEntries(5))
        let store = memoryStore()
        XCTAssertEqual(HistoryImporter.importIfNeeded(from: file, into: store, preferences: MemoryPreferenceStore()), 5)
        store.updateText(try XCTUnwrap(store.search("Entry 3", scope: .all).first), "Entry 3, edited")

        XCTAssertEqual(HistoryImporter.importIfNeeded(from: file, into: store, preferences: MemoryPreferenceStore()), 0)
        XCTAssertEqual(store.search("", scope: .all).count, 5)
    }

    /// Nothing is imported into a store that could not be opened, and the
    /// import is not marked done, so a later launch with a working store
    /// still imports.
    @MainActor
    func testNothingIsMarkedDoneWhileTheStoreIsUnavailable() throws {
        let file = try writeHistory(makeEntries(3))
        let brokenDirectory = directory.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenDirectory, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: brokenDirectory.appendingPathComponent("transcripts.store"))
        let broken = TranscriptStore(directory: brokenDirectory)
        guard case .unavailable = broken.health else { return XCTFail("health is \(broken.health)") }

        XCTAssertEqual(HistoryImporter.importIfNeeded(from: file, into: broken, preferences: preferences), 0)

        XCTAssertEqual(HistoryImporter.importIfNeeded(from: file, into: memoryStore(), preferences: preferences), 3)
    }

    /// A missing or unreadable file imports nothing and is not an import
    /// done, so a later launch tries again.
    @MainActor
    func testMissingOrUnreadableFileIsTriedAgain() throws {
        let file = directory.appendingPathComponent("history.json")
        let store = memoryStore()

        XCTAssertEqual(HistoryImporter.importIfNeeded(from: file, into: store, preferences: preferences), 0)
        try Data("[{\"text\": \"cut off".utf8).write(to: file)
        XCTAssertEqual(HistoryImporter.importIfNeeded(from: file, into: store, preferences: preferences), 0)
        XCTAssertEqual(store.search("", scope: .all), [])

        try writeHistory(makeEntries(2), to: file)
        XCTAssertEqual(HistoryImporter.importIfNeeded(from: file, into: store, preferences: preferences), 2)
    }

    // MARK: - Helpers

    /// An entry as the old app's `TranscriptionHistory` wrote it.
    private struct Entry: Encodable {
        let text: String
        let timestamp: Date
        let modelId: String
    }

    /// Whole seconds, as ISO 8601 keeps them; "Entry 0" is the oldest.
    private func makeEntries(_ count: Int) -> [Entry] {
        (0..<count).map { index in
            Entry(text: "Entry \(index)", timestamp: Date(timeIntervalSince1970: 1_774_000_000 + Double(index) * 60),
                  modelId: models[index % models.count])
        }
    }

    /// Writes `entries` newest first, with the old app's encoder settings.
    @discardableResult
    private func writeHistory(_ entries: [Entry], to url: URL? = nil) throws -> URL {
        let file = url ?? directory.appendingPathComponent("history.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(Array(entries.reversed())).write(to: file, options: .atomic)
        return file
    }

    @MainActor
    private func memoryStore() -> TranscriptStore {
        TranscriptStore(directory: directory.appendingPathComponent("unused", isDirectory: true), inMemory: true)
    }
}
