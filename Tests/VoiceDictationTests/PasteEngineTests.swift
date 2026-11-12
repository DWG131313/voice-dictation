import XCTest
import Cocoa
@testable import VoiceDictationLib

final class PasteEngineTests: XCTestCase {
    func testSnapshotAndRestoreRoundTripsMultipleTypes() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("vd-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setData(Data([1, 2, 3, 4]), forType: .png)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let snapshot = PasteEngine.snapshot(of: pasteboard)
        XCTAssertEqual(snapshot.items.count, 1)

        pasteboard.clearContents()
        pasteboard.setString("transcribed text", forType: .string)
        XCTAssertNil(pasteboard.data(forType: .png))

        PasteEngine.restore(snapshot, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "hello")
        XCTAssertEqual(pasteboard.data(forType: .png), Data([1, 2, 3, 4]))
    }

    func testRestoreOfEmptySnapshotLeavesPasteboardEmpty() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("vd-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        let snapshot = PasteEngine.snapshot(of: pasteboard)
        XCTAssertTrue(snapshot.items.isEmpty)

        pasteboard.setString("temporary", forType: .string)
        PasteEngine.restore(snapshot, to: pasteboard)
        XCTAssertNil(pasteboard.string(forType: .string))
    }
}
