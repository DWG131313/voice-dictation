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

    /// Without Accessibility access macOS ignores a synthetic Cmd+V, so the
    /// text is left on the clipboard for the user to paste, and the old
    /// clipboard is not put back over it. (Never test the trusted path: it
    /// would paste into whatever app is frontmost.)
    func testPasteWithoutAccessibilityLeavesTextOnClipboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("vd-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("copied earlier", forType: .string)
        let engine = PasteEngine(pasteboard: pasteboard, isTrusted: { false }, restoreDelay: 0.05)

        XCTAssertFalse(engine.paste(text: "dictated text"))
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated text")

        let pastRestoreDelay = expectation(description: "past the restore delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { pastRestoreDelay.fulfill() }
        wait(for: [pastRestoreDelay], timeout: 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated text", "the old clipboard came back over the text")
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
