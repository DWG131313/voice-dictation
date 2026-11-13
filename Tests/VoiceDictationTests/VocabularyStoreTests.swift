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

    @MainActor
    func testUnreadableFileLoadsEmptyAndStaysInPlace() throws {
        let url = try fileURL()
        try Data("not json {".utf8).write(to: url)
        let store = VocabularyStore(fileURL: url)
        XCTAssertEqual(store.words, [])
        XCTAssertEqual(store.replacements, [])
        XCTAssertEqual(try Data(contentsOf: url), Data("not json {".utf8), "loading leaves the bad file alone")
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
