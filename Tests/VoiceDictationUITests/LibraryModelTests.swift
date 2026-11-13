import AppKit
import XCTest
@testable import VoiceDictationLib
@testable import VoiceDictationUI

/// The transcript library's logic: which rows show, what is selected, what
/// each row and fact says, and what ⌘C copies. Stores are in memory or in a
/// temporary folder of their own, never the real `transcripts.store`.
final class LibraryModelTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_762_900_000)
    /// Folders made by `makeDirectory()`, removed after each test.
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    // MARK: - New transcripts

    @MainActor
    func testNewTranscriptAppearsFirst() throws {
        let store = memoryStore()
        store.add(outcome("First.", at: base))
        let library = LibraryModel(store: store)
        library.windowOpened()
        XCTAssertEqual(library.rows.map(\.text), ["First."])

        let newer = try XCTUnwrap(store.add(outcome("Second.", at: base.addingTimeInterval(60))))
        library.noteNewTranscript(newer)

        XCTAssertEqual(library.rows.map(\.text), ["Second.", "First."])
        XCTAssertEqual(library.count(of: .all, models: []), 2)
    }

    /// The spec: a new dictation appears at the top by itself, without
    /// stealing selection if Danny is reading another one.
    @MainActor
    func testNewTranscriptDoesNotStealSelection() throws {
        let store = memoryStore()
        let first = try XCTUnwrap(store.add(outcome("First.", at: base)))
        store.add(outcome("Second.", at: base.addingTimeInterval(60)))
        let library = LibraryModel(store: store)
        library.windowOpened()
        library.selection = first.id

        let third = try XCTUnwrap(store.add(outcome("Third.", at: base.addingTimeInterval(120))))
        library.noteNewTranscript(third)

        XCTAssertEqual(library.rows.first?.id, third.id)
        XCTAssertEqual(library.selection, first.id, "still reading the first")

        // Nothing selected: the new one is.
        library.selection = nil
        let fourth = try XCTUnwrap(store.add(outcome("Fourth.", at: base.addingTimeInterval(180))))
        library.noteNewTranscript(fourth)
        XCTAssertEqual(library.selection, fourth.id)

        // An empty library selects its first transcript.
        let emptyStore = memoryStore()
        let empty = LibraryModel(store: emptyStore)
        empty.windowOpened()
        XCTAssertNil(empty.selection)
        let only = try XCTUnwrap(emptyStore.add(outcome("Only.", at: base)))
        empty.noteNewTranscript(only)
        XCTAssertEqual(empty.selection, only.id)

        // One that is not listed here (not pinned, on Pinned) is not selected.
        let pinnedStore = memoryStore()
        let pinned = LibraryModel(store: pinnedStore)
        pinned.windowOpened()
        pinned.section = .pinned
        let unpinned = try XCTUnwrap(pinnedStore.add(outcome("Not pinned.", at: base)))
        pinned.noteNewTranscript(unpinned)
        XCTAssertEqual(pinned.rows.count, 0)
        XCTAssertNil(pinned.selection)
    }

    /// Nobody reads a closed window, so a dictation made while it is closed
    /// does not hold the selection: the window opens on the newest one,
    /// listed at the top, not on whichever was selected when it closed.
    @MainActor
    func testReopenedWindowSelectsTheNewest() throws {
        let store = memoryStore()
        let first = try XCTUnwrap(store.add(outcome("D1.", at: base)))
        let library = LibraryModel(store: store)
        library.windowOpened()
        XCTAssertEqual(library.selection, first.id)

        library.windowClosed()
        var newest = first
        for n in 2...5 {
            newest = try XCTUnwrap(store.add(outcome("D\(n).", at: base.addingTimeInterval(Double(n) * 60))))
            library.noteNewTranscript(newest)
        }
        library.windowOpened()

        XCTAssertEqual(library.rows.map(\.text), ["D5.", "D4.", "D3.", "D2.", "D1."])
        XCTAssertEqual(library.selection, newest.id, "the newest, at the top of the list")
        XCTAssertEqual(library.count(of: .all, models: []), 5)

        // Open again, a selection stays where Danny put it.
        library.selection = first.id
        let sixth = try XCTUnwrap(store.add(outcome("D6.", at: base.addingTimeInterval(360))))
        library.noteNewTranscript(sixth)
        XCTAssertEqual(library.selection, first.id)
    }

    /// While the window is closed a dictation costs the library nothing: no
    /// re-list and no counts, which opening does. (Not listing is how the
    /// test sees it: the rows are those of the last look.)
    @MainActor
    func testClosedWindowDoesNotRelist() throws {
        let store = memoryStore()
        store.add(outcome("First.", at: base))
        let library = LibraryModel(store: store)
        library.windowOpened()
        library.windowClosed()

        let second = try XCTUnwrap(store.add(outcome("Second.", at: base.addingTimeInterval(60))))
        library.noteNewTranscript(second)
        XCTAssertEqual(library.rows.map(\.text), ["First."], "not listed again while closed")
        XCTAssertEqual(library.count(of: .all, models: []), 1, "not counted again while closed")

        library.windowOpened()
        XCTAssertEqual(library.rows.map(\.text), ["Second.", "First."])
        XCTAssertEqual(library.count(of: .all, models: []), 2)
    }

    // MARK: - What a row says

    /// Ruling T18-2: a pinned calendar, time zone and locale, so these hold on any Mac.
    func testWhenString() {
        let now = at(2026, 11, 12, 20, 0)
        XCTAssertEqual(when(at(2026, 11, 12, 19, 42), now: now), "7:42 PM")
        XCTAssertEqual(when(at(2026, 11, 11, 9, 5), now: now), "Yesterday")
        XCTAssertEqual(when(at(2026, 11, 3, 16, 3), now: now), "Nov 3")

        // Days turn at midnight, not every 24 hours.
        let afterMidnight = at(2026, 11, 12, 0, 5)
        XCTAssertEqual(when(at(2026, 11, 12, 0, 1), now: afterMidnight), "12:01 AM")
        XCTAssertEqual(when(at(2026, 11, 11, 23, 59), now: afterMidnight), "Yesterday")
        XCTAssertEqual(when(at(2026, 11, 10, 23, 59), now: afterMidnight), "Nov 10")

        // Another year says which.
        XCTAssertEqual(when(at(2025, 11, 3, 16, 3), now: now), "Nov 3, 2025")

        // The calendar's time zone decides: the same moment is the next
        // afternoon in Tokyo.
        var tokyo = calendar
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(LibraryModel.whenString(at(2026, 11, 12, 19, 42), now: now, calendar: tokyo, locale: enUS),
                       "12:42 PM")
    }

    /// The detail's title always says the time of day: the row's short
    /// "Yesterday" and "Nov 3" gain it there.
    @MainActor
    func testTitleAlwaysHasTheTime() throws {
        let store = memoryStore()
        let t = try XCTUnwrap(store.add(outcome("Run the tests again.", at: at(2026, 11, 12, 19, 42))))
        t.appName = "Terminal"
        let now = at(2026, 11, 12, 20, 0)
        func title(_ date: Date) -> String {
            t.date = date
            return LibraryModel.title(t, now: now, calendar: calendar, locale: enUS)
        }

        XCTAssertEqual(title(at(2026, 11, 12, 19, 42)), "Terminal · 7:42 PM")
        XCTAssertEqual(title(at(2026, 11, 11, 18, 15)), "Terminal · Yesterday, 6:15 PM")
        XCTAssertEqual(title(at(2026, 11, 3, 16, 3)), "Terminal · Nov 3, 4:03 PM")
        XCTAssertEqual(title(at(2025, 1, 3, 16, 3)), "Terminal · Jan 3, 2025, 4:03 PM")
        // The row keeps its short words.
        XCTAssertEqual(LibraryModel.rowMeta(t, now: now, calendar: calendar, locale: enUS).when, "Jan 3, 2025")
    }

    func testLengthString() {
        XCTAssertEqual(LibraryModel.lengthString(14.2), "14s")
        XCTAssertEqual(LibraryModel.lengthString(75), "1m 15s")
        XCTAssertEqual(LibraryModel.lengthString(0.6), "1s")
        XCTAssertEqual(LibraryModel.lengthString(60), "1m")
        XCTAssertEqual(LibraryModel.lengthString(299.7), "5m")
    }

    /// The muted line over each row: the app, then `time · length`. The
    /// detail's title is the app and the time.
    @MainActor
    func testRowMetaAndTitle() throws {
        let store = memoryStore()
        let t = try XCTUnwrap(store.add(outcome("Run the tests again.", at: at(2026, 11, 12, 19, 42))))
        t.appName = "Terminal"
        t.recordingSeconds = 14.2
        let now = at(2026, 11, 12, 20, 0)

        let meta = LibraryModel.rowMeta(t, now: now, calendar: calendar, locale: enUS)
        XCTAssertEqual(meta.app, "Terminal")
        XCTAssertEqual(meta.when, "7:42 PM · 14s")
        XCTAssertEqual(LibraryModel.title(t, now: now, calendar: calendar, locale: enUS), "Terminal · 7:42 PM")

        // Imported history knows neither the app nor the length.
        t.appName = nil
        t.recordingSeconds = 0
        let unknown = LibraryModel.rowMeta(t, now: now, calendar: calendar, locale: enUS)
        XCTAssertEqual(unknown.app, "Unknown app")
        XCTAssertEqual(unknown.when, "7:42 PM")
    }

    // MARK: - The detail

    @MainActor
    func testFactsValues() throws {
        let store = memoryStore()
        let text = "Set up Tailscale on the Mac mini so the hub is reachable from my phone, then update the README with the steps."
        let t = try XCTUnwrap(store.add(outcome(text, at: base, transcribeSeconds: 0.3)))
        t.recordingSeconds = 14.2
        let models = [ModelDescriptor(id: .appleSpeech, displayName: "Apple Speech", detail: "", state: .ready)]

        let facts = LibraryModel.facts(t, models: models)

        XCTAssertEqual(facts.map(\.label), ["Length", "Transcribed in", "Model", "Words"])
        XCTAssertEqual(facts.map(\.value), ["14.2s", "0.3s", "Apple Speech", "22"])

        // A model that is not listed shows its key.
        XCTAssertEqual(LibraryModel.facts(t, models: []).map(\.value), ["14.2s", "0.3s", "appleSpeech/en-US", "22"])

        // Unknown timings (imported history) read as a dash, not 0.0s.
        t.recordingSeconds = 0
        t.transcribeSeconds = 0
        XCTAssertEqual(LibraryModel.facts(t, models: models).map(\.value), ["—", "—", "Apple Speech", "22"])
    }

    /// Status is a word. A failed dictation has no text, so it shows why.
    @MainActor
    func testStatusWordAndAFailedTranscriptShowsItsReason() throws {
        let store = memoryStore()
        let pasted = try XCTUnwrap(store.add(outcome("Hello there.", at: base)))
        let copied = try XCTUnwrap(store.add(outcome("Hello again.", at: base, status: .copied)))
        let failed = try XCTUnwrap(store.add(failedOutcome(DictationPipeline.skippedFailure)))

        XCTAssertEqual(LibraryModel.statusWord(pasted), "Pasted")
        XCTAssertEqual(LibraryModel.statusWord(copied), "Copied")
        XCTAssertEqual(LibraryModel.statusWord(failed), "Failed")

        XCTAssertEqual(LibraryModel.displayText(pasted).text, "Hello there.")
        XCTAssertFalse(LibraryModel.displayText(pasted).isReason)
        XCTAssertEqual(LibraryModel.displayText(failed).text, "Skipped: too many dictations waiting")
        XCTAssertTrue(LibraryModel.displayText(failed).isReason)
        XCTAssertEqual(LibraryModel.facts(failed, models: []).map(\.value), ["1.0s", "—", "appleSpeech/en-US", "0"])
    }

    // MARK: - Empty states and health

    @MainActor
    func testEmptyStates() throws {
        // No transcripts.
        let store = memoryStore()
        let library = LibraryModel(store: store)
        library.windowOpened()
        XCTAssertEqual(library.emptyMessage, "Nothing dictated yet. Hold Globe and speak.")

        // No search results.
        let t = try XCTUnwrap(store.add(outcome("Run the tests again.", at: base)))
        library.noteNewTranscript(t)
        XCTAssertNil(library.emptyMessage)
        library.query = "tailscale"
        XCTAssertEqual(library.emptyMessage, "No transcripts match “tailscale”.")
        library.query = "TESTS"
        XCTAssertNil(library.emptyMessage)
        XCTAssertEqual(library.rows.map(\.id), [t.id])

        // The store is unavailable: the health message (Review Focus 5).
        let parent = try makeDirectory()
        let inTheWay = parent.appendingPathComponent("VoiceDictation")
        try Data("A file, not a folder.".utf8).write(to: inTheWay)
        let unavailable = TranscriptStore(directory: inTheWay)
        guard case .unavailable(let message) = unavailable.health else {
            return XCTFail("health is \(unavailable.health)")
        }
        let broken = LibraryModel(store: unavailable)
        broken.reload()
        XCTAssertEqual(broken.emptyMessage, message)
        broken.query = "tests"
        XCTAssertEqual(broken.emptyMessage, message, "searching finds nothing either")
        XCTAssertNil(broken.notice)
    }

    /// Ruling T18-1: a store started anew after a damaged one was moved aside
    /// works as usual; its message shows as a notice above the list.
    @MainActor
    func testARecoveredStoreShowsItsNoticeAndWorks() throws {
        let directory = try makeDirectory()
        try Data("This is not a SQLite database.".utf8).write(to: directory.appendingPathComponent("transcripts.store"))
        let store = TranscriptStore(directory: directory)
        guard case .recovered(let message) = store.health else {
            return XCTFail("health is \(store.health)")
        }
        let library = LibraryModel(store: store)
        library.windowOpened()
        XCTAssertEqual(library.notice, message)
        XCTAssertEqual(library.emptyMessage, "Nothing dictated yet. Hold Globe and speak.")

        let t = try XCTUnwrap(store.add(outcome("Hello there.", at: base)))
        library.noteNewTranscript(t)

        XCTAssertEqual(library.rows.map(\.id), [t.id])
        XCTAssertEqual(library.selection, t.id)
        XCTAssertNil(library.emptyMessage)
        XCTAssertEqual(library.notice, message)

        let healthy = LibraryModel(store: memoryStore())
        healthy.reload()
        XCTAssertNil(healthy.notice)
    }

    // MARK: - Sections, search and the sidebar

    @MainActor
    func testSectionsAndSearchChooseTheRows() throws {
        let store = memoryStore()
        // Placed from the start of today, so a run just after midnight
        // cannot move any of them across the day (Ruling T18-2).
        let midnight = Calendar.current.startOfDay(for: Date())
        let older = try XCTUnwrap(store.add(outcome("Book the service appointment.", at: midnight.addingTimeInterval(-3 * 86_400))))
        let today = try XCTUnwrap(store.add(outcome("Run the tests again.", at: midnight.addingTimeInterval(1))))
        let pinned = try XCTUnwrap(store.add(outcome("Set up Tailscale.", at: midnight.addingTimeInterval(2))))
        store.setPinned(pinned, true)
        let library = LibraryModel(store: store)

        library.reload()
        XCTAssertEqual(library.rows.map(\.id), [pinned.id, today.id, older.id])
        XCTAssertEqual(library.selection, pinned.id, "the newest, when nothing was selected")

        library.selection = today.id
        library.section = .pinned
        XCTAssertEqual(library.rows.map(\.id), [pinned.id])
        XCTAssertEqual(library.selection, pinned.id, "a selection that is not listed moves to the first row")

        library.section = .today
        XCTAssertEqual(library.rows.map(\.id), [pinned.id, today.id])
        library.query = "tests"
        XCTAssertEqual(library.rows.map(\.id), [today.id])
        XCTAssertEqual(library.selection, today.id)

        // The setup sections leave the transcripts as they were.
        library.section = .models
        XCTAssertEqual(library.rows.map(\.id), [today.id])
        XCTAssertEqual(library.selection, today.id)
    }

    @MainActor
    func testSidebarCounts() throws {
        let store = memoryStore()
        let midnight = Calendar.current.startOfDay(for: Date())
        store.add(outcome("Older.", at: midnight.addingTimeInterval(-3 * 86_400)))
        store.add(outcome("Today.", at: midnight.addingTimeInterval(1)))
        let pinned = try XCTUnwrap(store.add(outcome("Pinned.", at: midnight.addingTimeInterval(-2 * 86_400))))
        store.setPinned(pinned, true)
        let library = LibraryModel(store: store)
        library.query = "today"
        library.reload()

        // Totals: the search does not narrow them.
        XCTAssertEqual(library.count(of: .all, models: []), 3)
        XCTAssertEqual(library.count(of: .today, models: []), 1)
        XCTAssertEqual(library.count(of: .pinned, models: []), 1)

        // Models counts those ready to use; none until they are listed.
        let tiny = ModelID(engine: .whisperKit, name: "openai_whisper-tiny.en")
        let models = [ModelDescriptor(id: .appleSpeech, displayName: "Apple Speech", detail: "", state: .ready),
                      ModelDescriptor(id: .appleDictation, displayName: "Apple Dictation", detail: "", state: .notDownloaded),
                      ModelDescriptor(id: tiny, displayName: "Tiny", detail: "", state: .ready)]
        XCTAssertEqual(library.count(of: .models, models: models), 2)
        XCTAssertNil(library.count(of: .models, models: []))
        XCTAssertNil(library.count(of: .vocabulary, models: models))
        XCTAssertNil(library.count(of: .settings, models: models))
    }

    // MARK: - Keyboard

    @MainActor
    func testUpDownMovesSelection() throws {
        let store = memoryStore()
        let a = try XCTUnwrap(store.add(outcome("A.", at: base)))
        let b = try XCTUnwrap(store.add(outcome("B.", at: base.addingTimeInterval(60))))
        let c = try XCTUnwrap(store.add(outcome("C.", at: base.addingTimeInterval(120))))
        let library = LibraryModel(store: store)
        library.reload()
        XCTAssertEqual(library.selection, c.id)

        library.moveSelection(by: 1)
        XCTAssertEqual(library.selection, b.id)
        library.moveSelection(by: 1)
        XCTAssertEqual(library.selection, a.id)
        library.moveSelection(by: 1)
        XCTAssertEqual(library.selection, a.id, "stays on the last row")
        library.moveSelection(by: -1)
        XCTAssertEqual(library.selection, b.id)

        library.selection = nil
        library.moveSelection(by: 1)
        XCTAssertEqual(library.selection, c.id, "down from nothing: the first row")
        library.selection = nil
        library.moveSelection(by: -1)
        XCTAssertEqual(library.selection, a.id, "up from nothing: the last row")

        let empty = LibraryModel(store: memoryStore())
        empty.reload()
        empty.moveSelection(by: 1)
        XCTAssertNil(empty.selection)
    }

    /// Ruling T18-3: ⌘C copies the selected part of the text when there is
    /// one, the whole transcript only when nothing in it is selected.
    func testCopyNeverStealsATextSelection() {
        let text = "Run the tests again."
        XCTAssertEqual(LibraryModel.textToCopy(text, selectedRange: NSRange(location: 4, length: 9)), "the tests")
        XCTAssertEqual(LibraryModel.textToCopy(text, selectedRange: NSRange(location: 4, length: 0)), text)
        XCTAssertEqual(LibraryModel.textToCopy(text, selectedRange: nil), text)
        // The range counts UTF-16 units, as a text view's does.
        XCTAssertEqual(LibraryModel.textToCopy("Ship it 🚀 now", selectedRange: NSRange(location: 8, length: 2)), "🚀")
        // A failed dictation has no text: nothing to copy.
        XCTAssertNil(LibraryModel.textToCopy("", selectedRange: nil))
    }

    /// ⌘C in the list uses the detail's text selection, which a new row clears.
    @MainActor
    func testCopyCommandFollowsTheDetailSelection() throws {
        let store = memoryStore()
        let older = try XCTUnwrap(store.add(outcome("Book the service appointment.", at: base)))
        store.add(outcome("Run the tests again.", at: base.addingTimeInterval(60)))
        let library = LibraryModel(store: store)
        library.windowOpened()
        XCTAssertEqual(library.copyCommandText, "Run the tests again.")

        library.textSelection = NSRange(location: 4, length: 9)
        XCTAssertEqual(library.copyCommandText, "the tests")

        library.selection = older.id
        XCTAssertNil(library.textSelection, "a new row has no text selected")
        XCTAssertEqual(library.copyCommandText, "Book the service appointment.")

        let failed = try XCTUnwrap(store.add(failedOutcome("Apple Speech language files are not installed")))
        library.noteNewTranscript(failed)
        library.selection = failed.id
        XCTAssertEqual(library.selectedTranscript?.id, failed.id)
        XCTAssertNil(library.copyCommandText, "a failed dictation has no text to copy")
    }

    /// The detail's text view: with text selected ⌘C copies that, with none
    /// the whole transcript, and Copy stays enabled with nothing selected.
    @MainActor
    func testTheTextViewCopiesItsSelectionOrTheWholeTranscript() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("vd-library-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let view = TranscriptTextView(frame: .zero)
        view.pasteboard = pasteboard
        view.string = "Run the tests again."
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")

        view.setSelectedRange(NSRange(location: 4, length: 9))
        XCTAssertTrue(view.validateMenuItem(copy))
        view.copy(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "the tests")

        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(view.validateMenuItem(copy), "nothing selected: Copy takes the whole transcript")
        view.copy(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "Run the tests again.")

        view.string = ""
        XCTAssertFalse(view.validateMenuItem(copy), "no text: nothing to copy")
    }

    /// The screen's only colour is the spectrum, so selecting text in the
    /// detail paints Prism's white on black, not the system accent.
    @MainActor
    func testSelectedTextIsPrismNotTheSystemAccent() {
        let view = TranscriptTextView(frame: .zero)
        XCTAssertEqual(view.selectedTextAttributes[.backgroundColor] as? NSColor, NSColor(Theme.Color.text))
        XCTAssertEqual(view.selectedTextAttributes[.foregroundColor] as? NSColor, NSColor(Theme.Color.bg))
        XCTAssertEqual(view.insertionPointColor, NSColor(Theme.Color.text))
    }

    // MARK: - Helpers

    private let enUS = Locale(identifier: "en_US")

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.locale = enUS
        return calendar
    }

    /// A local time in Los Angeles.
    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func when(_ date: Date, now: Date) -> String {
        LibraryModel.whenString(date, now: now, calendar: calendar, locale: enUS)
    }

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
            .appendingPathComponent("vd-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    private func outcome(_ text: String, at date: Date, transcribeSeconds: Double = 0.2,
                         status: DictationOutcome.Status = .pasted) -> DictationOutcome {
        DictationOutcome(date: date, clip: nil, rawText: text, text: text, model: .appleSpeech,
                         transcribeSeconds: transcribeSeconds, appName: "TextEdit", status: status)
    }

    private func failedOutcome(_ reason: String) -> DictationOutcome {
        DictationOutcome(date: base.addingTimeInterval(600), clip: AudioClip(samples: [Float](repeating: 0.1, count: 16_000)),
                         rawText: "", text: "", model: .appleSpeech, transcribeSeconds: 0,
                         appName: "TextEdit", status: .failed, failure: reason)
    }
}
