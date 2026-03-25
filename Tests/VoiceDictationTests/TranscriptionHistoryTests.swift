import XCTest
@testable import VoiceDictationLib

final class TranscriptionHistoryTests: XCTestCase {
    var history: TranscriptionHistory!
    var tempURL: URL!

    override func setUp() {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-history-\(UUID().uuidString).json")
        history = TranscriptionHistory(storageURL: tempURL, maxItems: 5)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testAddEntry() {
        history.add(text: "Hello world")
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.text, "Hello world")
    }

    func testMaxItemsEnforced() {
        for i in 0..<10 {
            history.add(text: "Entry \(i)")
        }
        XCTAssertEqual(history.entries.count, 5)
        // Most recent should be first
        XCTAssertEqual(history.entries.first?.text, "Entry 9")
    }

    func testPersistence() {
        history.add(text: "Persisted entry")

        // Create new instance pointing at same file
        let history2 = TranscriptionHistory(storageURL: tempURL, maxItems: 5)
        XCTAssertEqual(history2.entries.count, 1)
        XCTAssertEqual(history2.entries.first?.text, "Persisted entry")
    }

    func testClear() {
        history.add(text: "To be cleared")
        history.clear()
        XCTAssertEqual(history.entries.count, 0)
    }

    func testEntriesHaveTimestamp() {
        history.add(text: "Timestamped")
        let entry = history.entries.first!
        XCTAssertTrue(abs(entry.timestamp.timeIntervalSinceNow) < 2.0)
    }
}
