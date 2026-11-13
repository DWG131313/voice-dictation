import AppKit
import SwiftData
import XCTest
@testable import VoiceDictationLib
@testable import VoiceDictationUI

/// Task 19: what the detail's actions do. Each test has an in-memory store
/// with its recordings in a temporary folder of its own, `FakeEngine`s
/// behind a real `TranscriptionService`, a `FakePaster` (never the clipboard,
/// never a Cmd+V) and `FakeApps` in place of macOS's frontmost apps. No test
/// plays audio.
final class DetailActionsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_762_900_000)
    private let baseEn = ModelID(engine: .whisperKit, name: "openai_whisper-base.en")
    private let tiny = ModelID(engine: .whisperKit, name: "openai_whisper-tiny.en")
    private let clip = AudioClip(samples: [Float](repeating: 0.1, count: 16_000))
    private let paster = FakePaster()
    /// Folders made by `makeDirectory()`, removed after each test.
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    // MARK: - Re-transcribing

    /// A re-transcription is kept beside the transcript, with its model and
    /// the engine's time on the clip; `retranscribing` shows it while it runs.
    @MainActor
    func testRetranscribeAddsAlternateWithTiming() async throws {
        let whisper = FakeEngine(kind: .whisperKit, models: [ready(baseEn)])
        whisper.result = "Set up tail scale on the Mac mini."
        whisper.delay = 0.05
        whisper.isHeld = true
        let (library, store) = try rig([appleEngine(), whisper])
        let t = try XCTUnwrap(store.add(outcome("Set up Tailscale on the Mac mini.")))
        library.windowOpened()

        let running = Task { await library.retranscribe(t, with: baseEn) }
        try await waitUntil("it is re-transcribing") { library.retranscribing == [self.baseEn] }
        whisper.isHeld = false
        await running.value

        XCTAssertEqual(t.text, "Set up Tailscale on the Mac mini.", "the main text stays")
        XCTAssertEqual(t.alternates.count, 1)
        let alternate = try XCTUnwrap(t.alternates.first)
        XCTAssertEqual(alternate.text, "Set up tail scale on the Mac mini.")
        XCTAssertEqual(alternate.modelKey, baseEn.storageKey)
        XCTAssertFalse(alternate.wasMain)
        XCTAssertGreaterThanOrEqual(alternate.seconds, 0.05, "the engine's time on the clip")
        XCTAssertLessThan(alternate.seconds, 5)
        XCTAssertTrue(library.retranscribing.isEmpty)
        XCTAssertEqual(whisper.calls.filter { $0 == .transcribe(baseEn) }.count, 1)
        XCTAssertNil(library.message(for: t))
    }

    @MainActor
    func testRetranscribeSameModelTwiceReplacesNotDuplicates() async throws {
        let whisper = FakeEngine(kind: .whisperKit, models: [ready(baseEn)])
        let (library, store) = try rig([appleEngine(), whisper])
        let t = try XCTUnwrap(store.add(outcome("Hello there.")))

        whisper.result = "First try."
        await library.retranscribe(t, with: baseEn)
        whisper.result = "Second try."
        await library.retranscribe(t, with: baseEn)

        XCTAssertEqual(t.alternates.map(\.text), ["Second try."])
        XCTAssertEqual(t.alternates.map(\.modelKey), [baseEn.storageKey])
        XCTAssertEqual(try alternatesStored(in: store), 1)
    }

    /// "Use this one": the alternate becomes the main text with its model and
    /// time, and the text it replaces is kept, labelled as the former main
    /// text. The promoted alternate itself is gone (Task 11).
    @MainActor
    func testPromoteMakesAlternateMainAndKeepsOld() async throws {
        let whisper = FakeEngine(kind: .whisperKit, models: [ready(baseEn)])
        whisper.result = "Set up tail scale on the Mac mini."
        whisper.delay = 0.02
        let (library, store) = try rig([appleEngine(), whisper])
        let t = try XCTUnwrap(store.add(outcome("Set up Tailscale on the Mac mini.", transcribeSeconds: 0.3)))
        library.windowOpened()
        await library.retranscribe(t, with: baseEn)
        let alternate = try XCTUnwrap(t.alternates.first)
        let seconds = alternate.seconds

        library.promote(alternate, in: t)

        XCTAssertEqual(t.text, "Set up tail scale on the Mac mini.")
        XCTAssertEqual(t.modelKey, baseEn.storageKey)
        XCTAssertEqual(t.transcribeSeconds, seconds)
        XCTAssertEqual(t.rawText, "Set up Tailscale on the Mac mini.")
        XCTAssertEqual(LibraryModel.statusWord(t), "Pasted")
        XCTAssertEqual(t.alternates.count, 1)
        let old = try XCTUnwrap(t.alternates.first)
        XCTAssertEqual(old.text, "Set up Tailscale on the Mac mini.")
        XCTAssertTrue(old.wasMain)
        XCTAssertEqual(old.modelKey, "appleSpeech/en-US")
        XCTAssertEqual(old.seconds, 0.3)
        let columns = ComparisonView.columns(t, mainText: t.text, models: models)
        XCTAssertEqual(columns.map(\.title), ["Base", "Apple Speech"])
        XCTAssertEqual(columns.map(\.tag), ["In use", "Original"])
        XCTAssertEqual(columns.map(\.seconds), [String(format: "%.1fs", seconds), "0.3s"])
    }

    /// With its recording gone (pruned, or never kept), a transcript offers
    /// neither Play nor Re-transcribe, and says why.
    @MainActor
    func testActionsDisabledWithoutAudio() async throws {
        let whisper = FakeEngine(kind: .whisperKit, models: [ready(baseEn)])
        let (library, store) = try rig([appleEngine(), whisper])
        let kept = try XCTUnwrap(store.add(outcome("With its audio.", at: base)))
        let pruned = try XCTUnwrap(store.add(outcome("Without its audio.", at: base.addingTimeInterval(60))))
        pruned.audioFileName = nil
        library.windowOpened()

        XCTAssertNil(LibraryModel.audioUnavailableReason(kept))
        XCTAssertEqual(LibraryModel.retranscribeChoices(kept, models: models).map(\.id), [baseEn])
        XCTAssertEqual(LibraryModel.audioUnavailableReason(pruned), "Audio no longer kept")
        XCTAssertTrue(LibraryModel.retranscribeChoices(pruned, models: models).isEmpty)

        // Asked anyway, they do nothing but say why.
        library.togglePlay(pruned)
        XCTAssertNil(library.player.playing)
        XCTAssertFalse(library.isPlaying(pruned))
        await library.retranscribe(pruned, with: baseEn)
        XCTAssertTrue(whisper.calls.isEmpty)
        XCTAssertTrue(pruned.alternates.isEmpty)
        XCTAssertEqual(library.message(for: pruned), "Audio no longer kept")
    }

    /// Review Focus 1: a failed dictation, kept with its audio, re-transcribed:
    /// the result becomes its main text, goes on the clipboard (never pasted
    /// into whatever app is in front), and the transcript is Copied.
    @MainActor
    func testRetranscribeFailedTranscriptPromotesAutomatically() async throws {
        let apple = appleEngine()
        apple.result = "Hello there."
        let (library, store) = try rig([apple])
        let failed = try XCTUnwrap(store.add(failedOutcome("Apple Speech language files are not installed")))
        XCTAssertNotNil(failed.audioFileName)
        library.windowOpened()

        await library.retranscribe(failed, with: .appleSpeech)

        XCTAssertEqual(failed.text, "Hello there.")
        XCTAssertEqual(failed.modelKey, "appleSpeech/en-US")
        XCTAssertEqual(failed.status, .copied)
        XCTAssertEqual(LibraryModel.statusWord(failed), "Copied")
        XCTAssertFalse(LibraryModel.displayText(failed).isReason)
        XCTAssertEqual(paster.copied, ["Hello there."])
        XCTAssertTrue(paster.pasted.isEmpty)
        XCTAssertTrue(failed.alternates.isEmpty, "the failed dictation had no text to keep")
        XCTAssertEqual(library.message(for: failed), "Copied — paste with ⌘V")
    }

    /// Ruling T19-4: a failed transcript's re-transcription can finish long
    /// after the click, when dictations hold it up. Anything copied meanwhile
    /// stays on the clipboard: the transcript still takes the text and is
    /// Copied, and Danny is told to use Copy, which then copies it.
    @MainActor
    func testALateReTranscriptionLeavesWhatWasCopiedMeanwhile() async throws {
        let apple = appleEngine()
        apple.result = "Hello there."
        apple.isHeld = true
        let (library, store) = try rig([apple])
        let failed = try XCTUnwrap(store.add(failedOutcome("Apple Speech language files are not installed")))
        library.windowOpened()

        let running = Task { await library.retranscribe(failed, with: .appleSpeech) }
        try await waitUntil("the engine has the clip") { apple.calls.contains(.transcribe(.appleSpeech)) }
        paster.clipboardChangeCount += 1   // Danny copies something in another app.
        apple.isHeld = false
        await running.value

        XCTAssertEqual(failed.text, "Hello there.")
        XCTAssertEqual(failed.status, .copied)
        XCTAssertTrue(paster.copied.isEmpty, "what was copied meanwhile stays on the clipboard")
        XCTAssertTrue(paster.pasted.isEmpty)
        XCTAssertEqual(library.message(for: failed), "Re-transcribed — use Copy")

        library.copy(failed)
        XCTAssertEqual(paster.copied, ["Hello there."])
    }

    /// Ruling T19-4, the decision: a failed transcript's new text goes on the
    /// clipboard only if nothing was put there since its re-transcription
    /// was asked for. A click on "Use this one" copies at once.
    func testALateResultIsCopiedOnlyOntoAnUnchangedClipboard() {
        XCTAssertTrue(LibraryModel.copiesResult(clipboardWhenAsked: 7, clipboardNow: 7))
        XCTAssertFalse(LibraryModel.copiesResult(clipboardWhenAsked: 7, clipboardNow: 8), "something was copied meanwhile")
        XCTAssertTrue(LibraryModel.copiesResult(clipboardWhenAsked: nil, clipboardNow: 8), "a click copies at once")
    }

    /// A dictation skipped while Apple Speech was selected is kept as Failed
    /// under Apple Speech (`DictationPipelineTests.testQueueSkipsOldestBeyondThree`),
    /// and Re-transcribe with… offers Apple Speech too. Any other transcript
    /// is offered the ready models other than the one already used.
    @MainActor
    func testFailedTranscriptOffersItsOwnModel() throws {
        let (_, store) = try rig([appleEngine()])
        let models = [ready(.appleSpeech, "Apple Speech"), ready(.appleDictation, "Apple Dictation"),
                      ModelDescriptor(id: tiny, displayName: "Tiny", detail: "", state: .notDownloaded)]
        let skipped = try XCTUnwrap(store.add(failedOutcome(DictationPipeline.skippedFailure)))
        let pasted = try XCTUnwrap(store.add(outcome("Hello there.")))

        XCTAssertEqual(skipped.modelKey, "appleSpeech/en-US")
        XCTAssertEqual(LibraryModel.retranscribeChoices(skipped, models: models).map(\.id), [.appleSpeech, .appleDictation])
        XCTAssertEqual(LibraryModel.retranscribeChoices(pasted, models: models).map(\.id), [.appleDictation])
    }

    /// A failed dictation's re-transcription that finishes while Danny types
    /// in another transcript leaves that edit alone, even an emptied one he
    /// is about to type over.
    @MainActor
    func testAReTranscriptionFinishingElsewhereLeavesTheEditAlone() async throws {
        let apple = appleEngine()
        apple.isHeld = true
        let (library, store) = try rig([apple])
        let failed = try XCTUnwrap(store.add(failedOutcome("Apple Speech language files are not installed")))
        let typed = try XCTUnwrap(store.add(outcome("Hello there.", at: base)))
        library.windowOpened()
        library.selection = typed.id

        let running = Task { await library.retranscribe(failed, with: .appleSpeech) }
        try await waitUntil("the engine has the clip") { apple.calls.contains(.transcribe(.appleSpeech)) }
        library.edit(typed, text: "")
        apple.isHeld = false
        await running.value

        XCTAssertEqual(failed.status, .copied)
        XCTAssertEqual(library.shownText(typed), "", "still being typed over")
        XCTAssertEqual(typed.text, "Hello there.")
    }

    /// Deleted while a re-transcription runs: the result goes nowhere.
    @MainActor
    func testDeletingWhileReTranscribingDropsTheResult() async throws {
        let whisper = FakeEngine(kind: .whisperKit, models: [ready(baseEn)])
        whisper.isHeld = true
        let (library, store) = try rig([appleEngine(), whisper])
        let t = try XCTUnwrap(store.add(outcome("Hello there.")))
        library.windowOpened()

        let id = t.id
        let running = Task { await library.retranscribe(t, with: baseEn) }
        try await waitUntil("the engine has the clip") { whisper.calls.contains(.transcribe(self.baseEn)) }
        XCTAssertEqual(library.running, [id: [baseEn]])
        library.delete(t)
        whisper.isHeld = false
        await running.value

        XCTAssertTrue(store.search("", scope: .all).isEmpty)
        XCTAssertEqual(try alternatesStored(in: store), 0)
        // Read directly: with nothing selected now, `retranscribing` is empty whatever runs.
        XCTAssertTrue(library.running.isEmpty, "the run is over")
    }

    /// Review Focus 1's failure path: a failed transcript, selected, is
    /// re-transcribed with a model that will not load. It stays Failed, says
    /// why, and puts nothing on the clipboard; the run is over.
    @MainActor
    func testRetranscribingAFailedTranscriptWithAModelThatWillNotLoad() async throws {
        let apple = appleEngine()
        apple.unloadable = [.appleSpeech]
        let (library, store) = try rig([apple])
        let failed = try XCTUnwrap(store.add(failedOutcome("Apple Speech language files are not installed")))
        library.windowOpened()
        library.selection = failed.id

        await library.retranscribe(failed, with: .appleSpeech)

        XCTAssertEqual(library.message(for: failed), "Could not re-transcribe: en-US will not load")
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(paster.copied.isEmpty)
        XCTAssertEqual(library.selection, failed.id, "so `retranscribing` reads this transcript's runs")
        XCTAssertTrue(library.retranscribing.isEmpty)
        XCTAssertTrue(failed.alternates.isEmpty)
        XCTAssertEqual(apple.calls, [.prepare(.appleSpeech)], "it never reached the engine's transcribe")
    }

    // MARK: - Pin and Delete

    /// Deleting asks first only for a pinned transcript. The row below takes
    /// the selection, or the one above at the end of the list.
    @MainActor
    func testDeleteAsksOnlyForPinned() throws {
        let (library, store) = try rig()
        let a = try XCTUnwrap(store.add(outcome("A.", at: base)))
        let b = try XCTUnwrap(store.add(outcome("B.", at: base.addingTimeInterval(60))))
        let c = try XCTUnwrap(store.add(outcome("C.", at: base.addingTimeInterval(120))))
        library.windowOpened()
        library.selection = b.id

        library.delete(b)

        XCTAssertNil(library.deletionToConfirm)
        XCTAssertEqual(store.search("", scope: .all).map(\.text), ["C.", "A."])
        XCTAssertEqual(library.rows.map(\.text), ["C.", "A."])
        XCTAssertEqual(library.selection, a.id, "the row below takes its place")
        XCTAssertEqual(library.count(of: .all, models: []), 2)

        library.togglePin(c)
        library.selection = c.id
        library.delete(c)
        XCTAssertEqual(library.deletionToConfirm, c.id, "a pinned transcript asks first")
        XCTAssertEqual(store.search("", scope: .all).count, 2, "nothing deleted yet")
        library.cancelDeletion()
        XCTAssertNil(library.deletionToConfirm)
        XCTAssertEqual(store.search("", scope: .all).count, 2)

        library.delete(c, confirmed: true)
        XCTAssertNil(library.deletionToConfirm)
        XCTAssertEqual(store.search("", scope: .all).map(\.text), ["A."])
        XCTAssertEqual(library.selection, a.id)
        XCTAssertEqual(library.count(of: .pinned, models: []), 0)

        library.delete(a)
        XCTAssertTrue(library.rows.isEmpty)
        XCTAssertNil(library.selection)
    }

    /// Pin and unpin, counted at once. Unpinned on Pinned, it leaves the list.
    @MainActor
    func testPinTogglesAndRecounts() throws {
        let (library, store) = try rig()
        let older = try XCTUnwrap(store.add(outcome("Older.", at: base)))
        let newer = try XCTUnwrap(store.add(outcome("Newer.", at: base.addingTimeInterval(60))))
        library.windowOpened()

        library.togglePin(older)
        library.togglePin(newer)
        XCTAssertTrue(older.pinned)
        XCTAssertEqual(library.count(of: .pinned, models: []), 2)

        library.section = .pinned
        library.selection = newer.id
        library.togglePin(newer)
        XCTAssertFalse(newer.pinned)
        XCTAssertEqual(library.rows.map(\.id), [older.id])
        XCTAssertEqual(library.selection, older.id)
        XCTAssertEqual(library.count(of: .pinned, models: []), 1)
    }

    // MARK: - Editing

    /// An edit saves itself shortly after typing stops; the transcript then
    /// reads "Edited", keeps Revert to raw, and Copy and Paste again use the
    /// new text. An action saves an edit still being typed first.
    @MainActor
    func testEditSavesAndShowsEditedStatus() async throws {
        let (library, store) = try rig(editSaveDelay: .milliseconds(50))
        let t = try XCTUnwrap(store.add(outcome("Hello there.")))
        library.windowOpened()

        library.edit(t, text: "Hello there, Danny")
        library.edit(t, text: "Hello there, Danny.")
        XCTAssertEqual(t.text, "Hello there.", "nothing is saved while typing")
        XCTAssertEqual(library.shownText(t), "Hello there, Danny.")
        try await waitUntil("the edit saves itself") { t.text == "Hello there, Danny." }

        XCTAssertTrue(t.isEdited)
        XCTAssertEqual(LibraryModel.statusWord(t), "Edited")
        XCTAssertEqual(t.rawText, "Hello there.", "the raw text is never edited")
        XCTAssertTrue(LibraryModel.offersRevertToRaw(t))
        library.copy(t)
        XCTAssertEqual(paster.copied, ["Hello there, Danny."])
        await library.pasteAgain(t)
        XCTAssertEqual(paster.pasted, ["Hello there, Danny."])

        library.edit(t, text: "Hello again, Danny.")
        library.copy(t)
        XCTAssertEqual(t.text, "Hello again, Danny.")
        XCTAssertEqual(paster.copied.last, "Hello again, Danny.")

        library.revertToRaw(t)
        XCTAssertEqual(t.text, "Hello there.")
        XCTAssertEqual(LibraryModel.statusWord(t), "Pasted")
        XCTAssertFalse(LibraryModel.offersRevertToRaw(t))
        XCTAssertEqual(t.alternates.map(\.text), ["Hello again, Danny."], "the edit is kept")
    }

    /// An edit cannot leave the text empty: an empty text is never saved, and
    /// once the edit ends the previous text is back.
    @MainActor
    func testClearingTextRestoresPrevious() async throws {
        let (library, store) = try rig(editSaveDelay: .milliseconds(20))
        let other = try XCTUnwrap(store.add(outcome("Other.", at: base)))
        let t = try XCTUnwrap(store.add(outcome("Hello there.", at: base.addingTimeInterval(60))))
        library.windowOpened()
        library.edit(t, text: "Hello there, Danny.")
        try await waitUntil("the edit is saved") { t.text == "Hello there, Danny." }

        library.edit(t, text: "")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(t.text, "Hello there, Danny.", "an empty text is never saved")
        XCTAssertEqual(library.shownText(t), "", "it stays empty while Danny may type over it")

        library.commitEdit()
        XCTAssertEqual(library.shownText(t), "Hello there, Danny.", "the previous text is back")
        XCTAssertEqual(t.text, "Hello there, Danny.")
        XCTAssertTrue(t.isEdited)

        // Only whitespace counts as empty; selecting another transcript ends the edit too.
        library.edit(t, text: " \n ")
        library.selection = other.id
        library.selection = t.id
        XCTAssertEqual(library.shownText(t), "Hello there, Danny.")
        XCTAssertEqual(t.text, "Hello there, Danny.")
    }

    /// Typed, then another row selected before the save fires, then back:
    /// the edit was saved as the selection moved. Closing the window saves too.
    @MainActor
    func testEditSurvivesSelectionChange() throws {
        let (library, store) = try rig(editSaveDelay: .seconds(30))
        let older = try XCTUnwrap(store.add(outcome("Book the service appointment.", at: base)))
        let newer = try XCTUnwrap(store.add(outcome("Run the tests again.", at: base.addingTimeInterval(60))))
        library.windowOpened()
        XCTAssertEqual(library.selection, newer.id)

        library.edit(newer, text: "Run the tests again, please.")
        XCTAssertEqual(newer.text, "Run the tests again.", "not saved yet")
        library.selection = older.id
        XCTAssertEqual(newer.text, "Run the tests again, please.")
        XCTAssertTrue(newer.isEdited)
        library.selection = newer.id
        XCTAssertEqual(library.shownText(newer), "Run the tests again, please.")

        library.edit(newer, text: "Run all the tests again, please.")
        library.windowClosed()
        XCTAssertEqual(newer.text, "Run all the tests again, please.")
    }

    /// A cleanup that came back after the paste: "Use cleaned" makes it the
    /// main text. A cleanup in time, or none, offers nothing.
    @MainActor
    func testLateCleanedTextCanBePromoted() throws {
        let (library, store) = try rig()
        let late = try XCTUnwrap(store.add(outcome("um so ship it friday")))
        late.cleanedText = "So ship it Friday."   // as Task 21's setLateCleanup leaves it
        library.windowOpened()
        XCTAssertTrue(LibraryModel.offersUseCleaned(late))

        library.useCleaned(late)

        XCTAssertEqual(late.text, "So ship it Friday.")
        XCTAssertEqual(late.rawText, "um so ship it friday")
        XCTAssertFalse(late.isEdited)
        XCTAssertEqual(LibraryModel.statusWord(late), "Pasted")
        XCTAssertFalse(LibraryModel.offersUseCleaned(late), "it is the main text now")

        let inTime = try XCTUnwrap(store.add(outcome("So ship it Friday.", rawText: "um so ship it friday",
                                                     cleanedText: "So ship it Friday.")))
        XCTAssertFalse(LibraryModel.offersUseCleaned(inTime))
        XCTAssertFalse(LibraryModel.offersUseCleaned(try XCTUnwrap(store.add(outcome("Hello there.")))))
    }

    /// The text view is editable in Prism's face, with no spelling marks (the
    /// spectrum is the screen's only colour). ⌘Z undoes typing, and showing
    /// another transcript starts its undo afresh. The window is never shown.
    @MainActor
    func testTheTextViewEditsAndUndoesWithinOneTranscript() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = TranscriptText.makeTextView()
        window.contentView = view
        XCTAssertTrue(view.isEditable)
        XCTAssertTrue(view.allowsUndo)
        XCTAssertFalse(view.isRichText)
        XCTAssertFalse(view.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(view.isGrammarCheckingEnabled)
        let font = try XCTUnwrap(view.typingAttributes[.font] as? NSFont)
        XCTAssertEqual(font.pointSize, 16)
        XCTAssertEqual((view.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.minimumLineHeight, 16 * 1.65)

        view.show("Run the tests again.", fromTheTop: true)
        let undo = try XCTUnwrap(view.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        view.insertText(" Now.", replacementRange: NSRange(location: 20, length: 0))
        undo.endUndoGrouping()
        XCTAssertEqual(view.string, "Run the tests again. Now.")
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(view.string, "Run the tests again.")

        undo.beginUndoGrouping()
        view.insertText(" Now.", replacementRange: NSRange(location: 20, length: 0))
        undo.endUndoGrouping()
        view.show("Book the service appointment.", fromTheTop: true)
        XCTAssertFalse(undo.canUndo, "undo belongs to the transcript it was typed in")
        XCTAssertEqual(view.string, "Book the service appointment.")
    }

    // MARK: - Paste again (Ruling T19-3)

    /// Paste again pastes only into the app that was in front before this one.
    func testPasteAgainStep() {
        XCTAssertEqual(LibraryModel.pasteAgainStep(target: 42, frontmost: 42, waited: 0, limit: 1), .paste)
        XCTAssertEqual(LibraryModel.pasteAgainStep(target: 42, frontmost: 1, waited: 0.2, limit: 1), .wait)
        XCTAssertEqual(LibraryModel.pasteAgainStep(target: 42, frontmost: nil, waited: 0.2, limit: 1), .wait)
        XCTAssertEqual(LibraryModel.pasteAgainStep(target: 42, frontmost: 7, waited: 1, limit: 1), .copyInstead)
        XCTAssertEqual(LibraryModel.pasteAgainStep(target: 42, frontmost: 42, waited: 3, limit: 1), .paste,
                       "there now: paste")
        XCTAssertEqual(LibraryModel.pasteAgainStep(target: nil, frontmost: 7, waited: 0, limit: 1), .copyInstead,
                       "no app was in front before")
    }

    /// The window hides; once the previous app is in front again, the text pastes there.
    @MainActor
    func testPasteAgainHidesThenPastesIntoThePreviousApp() async throws {
        let apps = FakeApps()
        let (library, store) = try rig(apps: apps)
        let t = try XCTUnwrap(store.add(outcome("Hello there.")))

        await library.pasteAgain(t)

        XCTAssertEqual(apps.hides, 1)
        XCTAssertEqual(paster.pasted, ["Hello there."])
        XCTAssertTrue(paster.copied.isEmpty)
        XCTAssertEqual(apps.unhides, 0)
        XCTAssertNil(library.message(for: t))

        // A slow app: it waits until the previous app is in front.
        apps.frontmost = FakeApps.thisApp
        apps.frontmostAfterHide = nil
        let pasting = Task { await library.pasteAgain(t) }
        try await waitUntil("the window hides") { apps.hides == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(paster.pasted.count, 1, "not pasted while another app is in front")
        apps.frontmost = 42
        await pasting.value
        XCTAssertEqual(paster.pasted, ["Hello there.", "Hello there."])

        // Without Accessibility the paste cannot happen: the text is left on the clipboard.
        paster.succeeds = false
        await library.pasteAgain(t)
        XCTAssertEqual(library.message(for: t), "Copied — paste with ⌘V")
    }

    /// Never into the wrong app: if the previous app does not come back in
    /// time, the text goes on the clipboard and the window comes back to say
    /// so. With no previous app at all, the window does not hide.
    @MainActor
    func testPasteAgainCopiesWhenThePreviousAppDoesNotComeBack() async throws {
        let apps = FakeApps()
        apps.frontmostAfterHide = 7
        let (library, store) = try rig(apps: apps)
        library.pasteAgainWaitLimit = 0.1
        let t = try XCTUnwrap(store.add(outcome("Hello there.")))

        await library.pasteAgain(t)

        XCTAssertTrue(paster.pasted.isEmpty)
        XCTAssertEqual(paster.copied, ["Hello there."])
        XCTAssertEqual(library.message(for: t), "Copied — paste with ⌘V")
        XCTAssertEqual(apps.unhides, 1)

        apps.previous = nil
        await library.pasteAgain(t)
        XCTAssertEqual(apps.hides, 1, "nothing to go back to: the window stays")
        XCTAssertTrue(paster.pasted.isEmpty)
        XCTAssertEqual(paster.copied, ["Hello there.", "Hello there."])
    }

    /// macOS's side of Paste again shows the window again without activating
    /// the app (`unhideWithoutActivation`), so whichever app came to the front
    /// meanwhile keeps the keyboard. A stand-in takes `NSApplication`'s
    /// place: nothing is hidden or shown.
    @MainActor
    func testTheLiveSystemShowsTheWindowAgainWithoutActivating() {
        let application = FakeApplication()
        let system = PasteAgainSystem.live(application: application)

        system.hide()
        system.unhide()

        XCTAssertEqual(application.calls, [.hide, .unhideWithoutActivation])
    }

    // MARK: - The comparison

    /// The main text first, then the alternates, newest first, each headed by
    /// its model and seconds. A former main text is labelled as such, apart
    /// from a re-transcription by the same model; the words that differ from
    /// the main text are marked, and the main text's where any other differs.
    @MainActor
    func testComparisonColumns() throws {
        let (_, store) = try rig()
        let t = try XCTUnwrap(store.add(outcome("Set up Tailscale on the Mac mini.", transcribeSeconds: 0.3)))
        XCTAssertTrue(ComparisonView.columns(t, mainText: t.text, models: models).isEmpty, "no panel without alternates")
        store.addAlternate(to: t, TranscriptionResult(text: "Set up tail scale on the Mac mini.", model: baseEn, elapsed: 0.9))
        store.promote(try XCTUnwrap(t.alternates.first), in: t)
        store.addAlternate(to: t, TranscriptionResult(text: "Set up Tailscale on the Mac Mini.", model: .appleSpeech,
                                                     elapsed: 0.24))

        let columns = ComparisonView.columns(t, mainText: t.text, models: models)

        XCTAssertEqual(columns.map(\.title), ["Base", "Apple Speech", "Apple Speech"])
        XCTAssertEqual(columns.map(\.tag), ["In use", nil, "Original"])
        XCTAssertEqual(columns.map(\.seconds), ["0.9s", "0.2s", "0.3s"])
        XCTAssertEqual(columns.map { $0.alternateID == nil }, [true, false, false], "only alternates can be used")
        XCTAssertEqual(columns.first?.words.map(\.word), ["Set", "up", "tail", "scale", "on", "the", "Mac", "mini."])
        XCTAssertEqual(columns.map { $0.words.filter(\.isMarked).map(\.word) },
                       [["tail", "scale", "mini."], ["Tailscale", "Mini."], ["Tailscale"]])

        // A hand edit set aside is labelled as Danny's, under the model whose text he edited.
        store.updateText(t, "Set up Tailscale on the Mac mini, please.")
        store.promote(try XCTUnwrap(t.alternates.first { !$0.wasMain }), in: t)
        let edited = try XCTUnwrap(ComparisonView.columns(t, mainText: t.text, models: models)
            .first { $0.tag == "Edited" })
        XCTAssertEqual(edited.title, "Base")
    }

    /// `BenchReport.diffWords` marks changed words with `**`; the panel
    /// underlines them. A text with its own `**` is shown unmarked.
    func testMarkedWordsReadDiffWords() {
        let (a, b) = BenchReport.diffWords("ship it on friday now", "ship it friday right now")
        XCTAssertEqual(ComparisonView.markedWords(a).filter(\.isMarked).map(\.word), ["on"])
        XCTAssertEqual(ComparisonView.markedWords(b).filter(\.isMarked).map(\.word), ["right"])
        XCTAssertEqual(ComparisonView.markedWords(b).map(\.word), ["ship", "it", "friday", "right", "now"])

        let (c, _) = BenchReport.diffWords("one two three", "one 2 3")
        XCTAssertEqual(ComparisonView.markedWords(c).map(\.isMarked), [false, true, true])

        XCTAssertEqual(ComparisonView.marks("a **b** c", against: ["a b d"]).map(\.isMarked), [false, false, false])
        XCTAssertEqual(ComparisonView.marks("a **b** c", against: ["a b d"]).map(\.word), ["a", "**b**", "c"])
    }

    // MARK: - Playing

    /// A recording that cannot be read is not played. (No test plays audio:
    /// this file does not exist.)
    @MainActor
    func testAMissingRecordingIsNotPlayed() throws {
        let player = AudioPlayer()
        let missing = try makeDirectory().appendingPathComponent("missing.m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        XCTAssertThrowsError(try player.play(missing))
        XCTAssertNil(player.playing)
        player.stop()
        XCTAssertNil(player.playing)
    }

    // MARK: - Helpers

    private var models: [ModelDescriptor] {
        [ready(.appleSpeech, "Apple Speech"), ready(baseEn, "Base")]
    }

    /// A library over an in-memory store whose recordings go to a folder of
    /// this test's own.
    @MainActor
    private func rig(_ engines: [FakeEngine] = [], apps: FakeApps? = nil,
                     editSaveDelay: Duration = .seconds(30)) throws -> (LibraryModel, TranscriptStore) {
        let directory = try makeDirectory()
        let store = TranscriptStore(directory: directory, inMemory: true,
                                    audio: AudioArchive(directory: directory.appendingPathComponent("audio", isDirectory: true)))
        XCTAssertEqual(store.health, .ok)
        let library = LibraryModel(store: store, service: TranscriptionService(engines: engines, selected: .appleSpeech),
                                   paster: paster, system: (apps ?? FakeApps()).system, editSaveDelay: editSaveDelay)
        return (library, store)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vd-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    private func appleEngine() -> FakeEngine {
        FakeEngine(kind: .appleSpeech, models: [ready(.appleSpeech), ready(.appleDictation)])
    }

    private func ready(_ id: ModelID, _ name: String? = nil) -> ModelDescriptor {
        ModelDescriptor(id: id, displayName: name ?? id.name, detail: "", state: .ready)
    }

    @MainActor
    private func alternatesStored(in store: TranscriptStore) throws -> Int {
        try XCTUnwrap(store.container).mainContext.fetchCount(FetchDescriptor<AlternateResult>())
    }

    /// A pasted dictation by Apple Speech, kept with its recording.
    private func outcome(_ text: String, at date: Date? = nil, rawText: String? = nil, cleanedText: String? = nil,
                         transcribeSeconds: Double = 0.2) -> DictationOutcome {
        DictationOutcome(date: date ?? base, clip: clip, rawText: rawText ?? text, cleanedText: cleanedText, text: text,
                         model: .appleSpeech, transcribeSeconds: transcribeSeconds, appName: "TextEdit", status: .pasted)
    }

    /// A dictation that failed (or was skipped) while Apple Speech was
    /// selected, kept with its recording, as the pipeline reports it.
    private func failedOutcome(_ reason: String) -> DictationOutcome {
        DictationOutcome(date: base.addingTimeInterval(600), clip: clip, rawText: "", text: "", model: .appleSpeech,
                         transcribeSeconds: 0, appName: "TextEdit", status: .failed, failure: reason)
    }

    private struct Timeout: Error {}

    /// Polls every 10 ms until `condition` holds; fails after `limit` seconds.
    @MainActor
    private func waitUntil(_ what: String, within limit: TimeInterval = 2,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(limit)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Waited \(limit) s for: \(what)", file: file, line: line)
                throw Timeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
