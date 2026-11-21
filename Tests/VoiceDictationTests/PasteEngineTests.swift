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

    // MARK: - Putting the clipboard back (code review, 2026-11-20)

    /// The trusted path, with a stand-in for the keystroke: nothing is
    /// posted to the app in front.
    private func trustedEngine(_ pasteboard: NSPasteboard, posts: @escaping () -> Void = {}) -> PasteEngine {
        PasteEngine(pasteboard: pasteboard, isTrusted: { true }, restoreDelay: 0.1,
                    postPaste: { posts(); return true })
    }

    private func waitPastTheRestore() {
        let past = expectation(description: "past the restore delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { past.fulfill() }
        wait(for: [past], timeout: 2)
    }

    func testAPastePutsBackWhatWasCopied() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("vd-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("copied earlier", forType: .string)
        var posts = 0
        let engine = trustedEngine(pasteboard) { posts += 1 }

        XCTAssertTrue(engine.paste(text: "dictated text"))
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated text")
        XCTAssertEqual(posts, 1)
        waitPastTheRestore()
        XCTAssertEqual(pasteboard.string(forType: .string), "copied earlier")
    }

    /// Two pastes closer together than the restore delay: what was copied
    /// before the first comes back, not the first paste's text.
    func testTwoQuickPastesPutBackWhatWasCopiedBeforeTheFirst() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("vd-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("copied earlier", forType: .string)
        let engine = trustedEngine(pasteboard)

        XCTAssertTrue(engine.paste(text: "first dictation"))
        XCTAssertTrue(engine.paste(text: "second dictation"))
        XCTAssertEqual(pasteboard.string(forType: .string), "second dictation")
        waitPastTheRestore()
        XCTAssertEqual(pasteboard.string(forType: .string), "copied earlier",
                       "the first dictation came back in place of the copy")
    }

    /// Something copied between two pastes is newer than the first copy, so
    /// it is what comes back.
    func testACopyBetweenTwoPastesIsWhatComesBack() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("vd-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("copied earlier", forType: .string)
        let engine = trustedEngine(pasteboard)

        XCTAssertTrue(engine.paste(text: "first dictation"))
        pasteboard.clearContents()
        pasteboard.setString("copied in between", forType: .string)
        XCTAssertTrue(engine.paste(text: "second dictation"))
        waitPastTheRestore()
        XCTAssertEqual(pasteboard.string(forType: .string), "copied in between")
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

    func testTheProjectIsTheFolderTheWindowIsOpenOn() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        XCTAssertEqual(PasteEngine.projectName(fromDocument: "file:///Users/someone/CodingProjects/Voice%20Dictation/", home: home), "Voice Dictation")
        XCTAssertEqual(PasteEngine.projectName(fromDocument: "file:///Users/someone/CodingProjects/", home: home), "CodingProjects")
        XCTAssertNil(PasteEngine.projectName(fromDocument: "file:///Users/someone/CodingProjects/Voice%20Dictation/README.md", home: home), "a document, not a folder")
        XCTAssertNil(PasteEngine.projectName(fromDocument: "file:///Users/someone/", home: home), "the home folder")
        XCTAssertNil(PasteEngine.projectName(fromDocument: "file:///", home: home))
        XCTAssertNil(PasteEngine.projectName(fromDocument: "https://example.com/folder/", home: home))
        XCTAssertNil(PasteEngine.projectName(fromDocument: nil, home: home))
    }
}
