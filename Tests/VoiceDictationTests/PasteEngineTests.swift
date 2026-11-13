import XCTest
import Carbon.HIToolbox
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

    /// Copy (Task 19) puts the text on the clipboard and leaves it there: no
    /// Cmd+V, and the old clipboard does not come back over it. The engine is
    /// not trusted, so even a paste by mistake could post no keystroke.
    func testCopyLeavesTheTextOnTheClipboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("vd-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("copied earlier", forType: .string)
        let engine = PasteEngine(pasteboard: pasteboard, isTrusted: { false }, restoreDelay: 0.05)

        engine.copy(text: "transcript text")
        XCTAssertEqual(pasteboard.string(forType: .string), "transcript text")

        let pastRestoreDelay = expectation(description: "past the restore delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { pastRestoreDelay.fulfill() }
        wait(for: [pastRestoreDelay], timeout: 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "transcript text", "the old clipboard came back over the text")
    }

    /// The clipboard's change count is the engine's own pasteboard's (Ruling
    /// T19-4): it goes up with the engine's copy, and with a copy made by
    /// anyone else. Nothing is pasted: the engine is not trusted.
    func testClipboardChangeCountIsThePasteboards() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("vd-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let engine = PasteEngine(pasteboard: pasteboard, isTrusted: { false }, restoreDelay: 0.05)
        let before = engine.clipboardChangeCount
        XCTAssertEqual(before, pasteboard.changeCount)

        engine.copy(text: "transcript text")
        XCTAssertGreaterThan(engine.clipboardChangeCount, before)

        let afterCopy = engine.clipboardChangeCount
        pasteboard.clearContents()   // another app copies something
        pasteboard.setString("copied elsewhere", forType: .string)
        XCTAssertGreaterThan(engine.clipboardChangeCount, afterCopy)
        XCTAssertEqual(engine.clipboardChangeCount, pasteboard.changeCount)
    }

    /// The Cmd+V the engine posts carries `PasteEngine.eventTag`, so the
    /// hotkey's event tap can tell the app's own paste from a key the user
    /// pressed. The events are only made here, never posted.
    func testPasteKeystrokesCarryTheAppsTag() throws {
        let keystrokes = try XCTUnwrap(PasteEngine.pasteKeystrokes())

        XCTAssertEqual(keystrokes.down.type, .keyDown)
        XCTAssertEqual(keystrokes.up.type, .keyUp)
        for event in [keystrokes.down, keystrokes.up] {
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_ANSI_V))
            XCTAssertTrue(event.flags.contains(.maskCommand))
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), PasteEngine.eventTag)
        }
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
