import XCTest
@testable import VoiceDictationLib

/// Task 22: `VocabularyStore`, always over a temporary file, never the real one.
final class VocabularyStoreTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func fileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vd-vocab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory.appendingPathComponent("vocabulary.json")
    }

    @MainActor
    func testMissingFileLoadsEmpty() throws {
        let store = VocabularyStore(fileURL: try fileURL())
        XCTAssertEqual(store.words, [])
        XCTAssertEqual(store.replacements, [])
    }

    @MainActor
    func testRoundTrip() throws {
        let url = try fileURL()
        let store = VocabularyStore(fileURL: url)
        store.words = ["Tailscale", "SwiftData"]
        store.replacements = [Replacement(from: "gv seventy", to: "GV70")]
        store.save()

        let again = VocabularyStore(fileURL: url)
        XCTAssertEqual(again.words, ["Tailscale", "SwiftData"])
        XCTAssertEqual(again.replacements, [Replacement(from: "gv seventy", to: "GV70")])
    }

    @MainActor
    func testBlankAndDuplicateWordsDropped() throws {
        let url = try fileURL()
        let store = VocabularyStore(fileURL: url)
        store.words = ["Tailscale", "  ", "tailscale", " Quickel ", "", "TAILSCALE"]
        store.replacements = [Replacement(from: "a", to: "b"), Replacement(from: "  ", to: "x"), Replacement(from: "A", to: "c")]
        XCTAssertEqual(store.activeWords, ["Tailscale", "Quickel"])
        XCTAssertEqual(store.activeReplacements, [Replacement(from: "a", to: "b"), Replacement(from: "A", to: "c")],
                       "blank rules are dropped; the apply step handles the same from twice")
        store.save()

        XCTAssertEqual(store.words.count, 6, "rows being edited stay on screen")
        XCTAssertEqual(VocabularyStore(fileURL: url).words, ["Tailscale", "Quickel"])
        XCTAssertEqual(VocabularyStore(fileURL: url).replacements.count, 2)
    }

    @MainActor
    func testAddWordSkipsBlankAndRepeatedWords() throws {
        let store = VocabularyStore(fileURL: try fileURL())
        XCTAssertTrue(store.addWord("  Tailscale "))
        XCTAssertFalse(store.addWord("tailscale"))
        XCTAssertFalse(store.addWord("   "))
        XCTAssertEqual(store.words, ["Tailscale"])
    }

    /// A file that is there but is not valid is moved aside, never
    /// overwritten by a later save.
    @MainActor
    func testUndecodableFileIsMovedAsideAndSurvivesLaterSaves() throws {
        let url = try fileURL()
        let bad = Data("{ \"words\": [oops".utf8)
        try bad.write(to: url)

        let store = VocabularyStore(fileURL: url)
        XCTAssertEqual(store.words, [])
        XCTAssertEqual(store.replacements, [])
        store.addWord("Tailscale")
        store.save()

        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted()
        XCTAssertEqual(names.count, 2)
        let broken = try XCTUnwrap(names.first { $0.hasPrefix("vocabulary.json.broken-") })
        XCTAssertEqual(try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(broken)), bad)
        XCTAssertEqual(VocabularyStore(fileURL: url).words, ["Tailscale"])
    }

    /// An error reading the file moves nothing aside, and saves nothing this session.
    @MainActor
    func testReadErrorMovesNothingAndNeverSaves() throws {
        let url = try fileURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)  // unreadable as a file
        let store = VocabularyStore(fileURL: url)
        XCTAssertEqual(store.words, [])
        store.addWord("Tailscale")
        store.save()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "nothing replaced it")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["vocabulary.json"])
    }

    /// Rows have identities that outlive edits and removals.
    @MainActor
    func testRowsKeepTheirIdentityThroughEditsAndRemovals() throws {
        let store = VocabularyStore(fileURL: try fileURL())
        store.addWord("one"); store.addWord("two"); store.addWord("three")
        let ids = store.wordRows.map(\.id)
        XCTAssertEqual(Set(ids).count, 3)

        store.wordRows[1].text = "tw"            // being edited...
        store.removeWord(id: ids[0])             // ...while another row goes
        store.wordRows[0].text = "two!"          // the edited row, now first

        XCTAssertEqual(store.wordRows.map(\.id), [ids[1], ids[2]])
        XCTAssertEqual(store.words, ["two!", "three"])
        store.removeWord(id: ids[0])             // already gone: harmless
        XCTAssertEqual(store.words, ["two!", "three"])

        store.addReplacement(from: "a", to: "b"); store.addReplacement(from: "c", to: "d")
        let ruleIDs = store.ruleRows.map(\.id)
        store.removeRule(id: ruleIDs[0])
        XCTAssertEqual(store.replacements, [Replacement(from: "c", to: "d")])
        XCTAssertEqual(store.ruleRows.map(\.id), [ruleIDs[1]])
    }

    @MainActor
    func testSaveCreatesMissingFolderAndLeavesNoTemporaryFiles() throws {
        let url = try fileURL().deletingLastPathComponent().appendingPathComponent("deeper/vocabulary.json")
        let store = VocabularyStore(fileURL: url)
        store.words = ["Tailscale"]
        store.save()
        XCTAssertEqual(VocabularyStore(fileURL: url).words, ["Tailscale"])
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["vocabulary.json"])
    }
}
