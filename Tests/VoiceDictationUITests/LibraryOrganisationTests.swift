import XCTest
@testable import VoiceDictationLib
@testable import VoiceDictationUI

/// The list organised: by day and by place, narrowed by length or by a
/// project or app from the Projects & apps panel, folded, and emptied a
/// heading at a time after asking. Stores are in memory; recordings, when a
/// test needs them, go to a temporary folder of its own.
final class LibraryOrganisationTests: XCTestCase {
    /// Noon today on this Mac: transcripts a few minutes either side of it
    /// are all today, in any time zone. The library groups and names days
    /// with the Mac's own calendar and clock.
    private let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    private var yesterdayNoon: Date { Calendar.current.date(byAdding: .day, value: -1, to: noon)! }
    /// Folders made by `makeDirectory()`, removed after each test.
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    // MARK: - Places and length

    @MainActor
    func testChoosingAPlaceListsItAcrossDays() throws {
        let store = memoryStore()
        store.add(outcome("Yesterday's fix.", at: yesterdayNoon, appName: "Terminal", project: "Voice Dictation"))
        store.add(outcome("Today's fix.", at: noon, appName: "Terminal", project: "Voice Dictation"))
        store.add(outcome("A note.", at: noon.addingTimeInterval(60), appName: "Notes"))
        store.add(outcome("Another repo.", at: noon.addingTimeInterval(120), appName: "Terminal", project: "Emulation"))
        let library = makeLibrary(store)
        library.windowOpened()

        library.isPlacesPanelOpen = true
        XCTAssertEqual(library.placeEntries.map(\.title), ["Terminal", "Voice Dictation", "Emulation", "Notes"],
                       "opening the panel lists the places")
        library.show(.place(Place(app: "Terminal", project: "Voice Dictation")))

        XCTAssertEqual(library.section, .places)
        XCTAssertFalse(library.isPlacesPanelOpen)
        XCTAssertEqual(library.scope, .place(.place(Place(app: "Terminal", project: "Voice Dictation"))))
        XCTAssertEqual(library.days.count, 2)
        XCTAssertEqual(library.rows.map(\.text), ["Today's fix.", "Yesterday's fix."])
        XCTAssertTrue(library.rows.allSatisfy { $0.project == "Voice Dictation" })
        XCTAssertFalse(library.showsGroupHeadings)
        XCTAssertEqual(library.placeTitle, "Voice Dictation")
        XCTAssertNil(library.count(of: .places, models: []))

        library.show(.app("Terminal"))
        XCTAssertTrue(library.showsGroupHeadings, "Terminal's rows are from two folders")
        XCTAssertEqual(library.placeTitle, "Terminal")
        XCTAssertEqual(library.rows.map(\.text), ["Another repo.", "Today's fix.", "Yesterday's fix."])

        library.show(.app("Notes"))
        XCTAssertFalse(library.showsGroupHeadings, "every one of Notes' rows is from one place")
        XCTAssertEqual(library.visibleRows.map(\.text), ["A note."])

        // Choosing All leaves the place.
        library.section = .all
        XCTAssertNil(library.place)
        XCTAssertNil(library.placeTitle)
        XCTAssertTrue(library.showsGroupHeadings)
        XCTAssertEqual(library.rows.count, 4)
    }

    /// The sidebar names the place showing: its folder, or else its app,
    /// and an app's transcripts without a folder say so. A place emptied by
    /// deleting says so in the list, by that name.
    @MainActor
    func testAPlaceIsNamedAndSaysWhenItIsEmpty() throws {
        let store = memoryStore()
        store.add(outcome("A note.", at: noon, appName: "Notes"))
        store.add(outcome("A fix.", at: noon.addingTimeInterval(60), appName: "Terminal", project: "Voice Dictation"))
        let library = makeLibrary(store)
        library.windowOpened()

        library.show(.place(Place(app: "Terminal", project: "Voice Dictation")))
        XCTAssertEqual(library.placeTitle, "Voice Dictation")
        library.show(.place(Place(app: "Terminal", project: nil)))
        XCTAssertEqual(library.placeTitle, "Terminal · No folder recorded")
        XCTAssertEqual(library.emptyMessage, "No transcripts from Terminal · No folder recorded.")
        library.show(.app(nil))
        XCTAssertEqual(library.placeTitle, "Unknown app")

        library.show(.app("Notes"))
        XCTAssertEqual(library.placeTitle, "Notes")
        XCTAssertNil(library.emptyMessage)
        library.askToDelete(day: try XCTUnwrap(library.days.first))
        library.confirmHeadingDeletion()
        XCTAssertTrue(library.rows.isEmpty)
        XCTAssertEqual(library.emptyMessage, "No transcripts from Notes.")
        library.length = .short
        XCTAssertEqual(library.emptyMessage, "No transcripts of that length.", "a length says so first")
    }

    @MainActor
    func testLengthNarrowsTheList() {
        let store = memoryStore()
        store.add(outcome("Short.", at: noon, seconds: 4))
        store.add(outcome("Long.", at: noon.addingTimeInterval(60), seconds: 75))
        store.add(outcome("Imported.", at: noon.addingTimeInterval(120)))
        let library = makeLibrary(store)
        library.windowOpened()

        library.length = .short
        XCTAssertEqual(library.rows.map(\.text), ["Short."])
        XCTAssertTrue(library.rows.allSatisfy { $0.recordingSeconds > 0 && $0.recordingSeconds < 10 })
        XCTAssertEqual(library.days.flatMap(\.transcripts).map(\.text), ["Short."], "the days are the rows")

        library.length = .long
        XCTAssertEqual(library.rows.map(\.text), ["Long."])
        library.query = "short"
        XCTAssertEqual(library.emptyMessage, "No transcripts match “short”.", "the search says so first")
        library.query = ""

        library.length = .medium
        XCTAssertTrue(library.rows.isEmpty)
        XCTAssertEqual(library.emptyMessage, "No transcripts of that length.")

        library.length = .any
        XCTAssertEqual(library.rows.map(\.text), ["Imported.", "Long.", "Short."], "an unknown length shows under Any")
        XCTAssertEqual(library.count(of: .all, models: []), 3)
    }

    // MARK: - Folding

    @MainActor
    func testFoldingHidesRowsFromTheKeyboard() throws {
        let store = memoryStore()
        // Groups sit in the order of their newest row: A's are the newest.
        let b1 = try XCTUnwrap(store.add(outcome("B one.", at: noon, appName: "Notes")))
        let a2 = try XCTUnwrap(store.add(outcome("A two.", at: noon.addingTimeInterval(60),
                                                 appName: "Terminal", project: "Voice Dictation")))
        let a1 = try XCTUnwrap(store.add(outcome("A one.", at: noon.addingTimeInterval(120),
                                                 appName: "Terminal", project: "Voice Dictation")))
        let library = makeLibrary(store)
        library.windowOpened()
        XCTAssertEqual(library.days.count, 1)
        let today = try XCTUnwrap(library.days.first)
        XCTAssertEqual(today.groups.count, 2)
        let groupA = today.groups[0]
        let groupB = today.groups[1]
        XCTAssertEqual(groupA.transcripts.map(\.id), [a1.id, a2.id])
        XCTAssertEqual(library.selection, a1.id)

        library.toggleFold(groupB.id)
        XCTAssertTrue(library.isFolded(groupB.id))
        XCTAssertEqual(library.visibleRows.map(\.id), [a1.id, a2.id])
        library.moveSelection(by: 1); library.moveSelection(by: 1)
        XCTAssertEqual(library.selection, a2.id, "stops at the last visible row")
        library.toggleFold(groupA.id)   // the selected row folds away
        XCTAssertNil(library.selection, "nothing visible is left")

        library.toggleFold(groupB.id)
        library.toggleFold(groupA.id)
        XCTAssertFalse(library.isFolded(groupA.id))
        XCTAssertEqual(library.visibleRows.map(\.id), [a1.id, a2.id, b1.id])
        library.selection = a1.id
        library.toggleFold(groupA.id)
        XCTAssertEqual(library.selection, b1.id, "the nearest visible row")

        library.askToDelete(day: today)
        XCTAssertEqual(library.headingDeletionToConfirm?.ids.count, 3, "a folded group's rows are still under the day")
        library.cancelHeadingDeletion()

        library.toggleFold(today.id)
        XCTAssertTrue(library.visibleRows.isEmpty, "a folded day hides its groups")
        XCTAssertNil(library.selection)
    }

    /// A place showing alone has no group headings, so a group folded in
    /// the full list cannot hide its rows there: there is nothing to open.
    @MainActor
    func testAGroupFoldedElsewhereStillShowsWhenItsPlaceIsChosen() throws {
        let store = memoryStore()
        let fix = try XCTUnwrap(store.add(outcome("A fix.", at: noon, appName: "Terminal", project: "Voice Dictation")))
        store.add(outcome("A note.", at: noon.addingTimeInterval(60), appName: "Notes"))
        let library = makeLibrary(store)
        library.windowOpened()
        let group = try XCTUnwrap(library.days.first?.groups.first { $0.place.project == "Voice Dictation" })
        library.toggleFold(group.id)

        library.show(.place(group.place))
        XCTAssertEqual(library.visibleRows.map(\.id), [fix.id])
        XCTAssertEqual(library.selection, fix.id)

        library.section = .all
        XCTAssertTrue(library.isFolded(group.id), "folds last while the app runs")
        XCTAssertFalse(library.visibleRows.contains { $0.id == fix.id })
        XCTAssertNotEqual(library.selection, fix.id, "the selection moves off a row that is folded away")
    }

    /// Heading ids last from day to day, so a heading deleted while folded
    /// forgets its fold: the next dictation there shows, and is selected as
    /// a new one is. A search that only hides a heading keeps its fold.
    @MainActor
    func testDeletingAFoldedHeadingForgetsItsFold() throws {
        let store = memoryStore()
        store.add(outcome("A note.", at: noon, appName: "Notes"))
        store.add(outcome("A fix.", at: noon.addingTimeInterval(60), appName: "Terminal", project: "Voice Dictation"))
        let library = makeLibrary(store)
        library.windowOpened()
        var today = try XCTUnwrap(library.days.first)
        let notes = try XCTUnwrap(today.groups.first { $0.place.app == "Notes" })

        library.toggleFold(notes.id)
        library.query = "fix"
        library.query = ""
        XCTAssertTrue(library.isFolded(notes.id), "a search that hid it does not forget it")

        library.askToDelete(group: notes, on: today)
        library.confirmHeadingDeletion()
        XCTAssertFalse(library.isFolded(notes.id))
        let note = try XCTUnwrap(store.add(outcome("Another note.", at: noon.addingTimeInterval(120), appName: "Notes")))
        library.noteNewTranscript(note)
        XCTAssertTrue(library.visibleRows.contains { $0.id == note.id }, "the group comes back open")

        today = try XCTUnwrap(library.days.first)
        let groups = today.groups.map(\.id)
        library.toggleFold(today.id)
        for group in groups { library.toggleFold(group) }
        XCTAssertNil(library.selection, "everything is folded away")
        library.askToDelete(day: today)
        library.confirmHeadingDeletion()
        XCTAssertTrue(library.days.isEmpty)
        XCTAssertFalse(library.isFolded(today.id))
        XCTAssertFalse(groups.contains { library.isFolded($0) }, "the day's groups forget theirs too")

        let fresh = try XCTUnwrap(store.add(outcome("A new day's fix.", at: noon.addingTimeInterval(180),
                                                    appName: "Terminal", project: "Voice Dictation")))
        library.noteNewTranscript(fresh)
        XCTAssertEqual(library.days.first?.id, today.id, "the same day's heading is back")
        XCTAssertEqual(library.visibleRows.map(\.id), [fresh.id])
        XCTAssertEqual(library.selection, fresh.id)
    }

    // MARK: - Deleting a heading

    @MainActor
    func testDeletingAGroupAsksFirstAndKeepsPinned() throws {
        let store = memoryStore()
        store.add(outcome("One.", at: noon, appName: "Terminal", project: "Voice Dictation"))
        let two = try XCTUnwrap(store.add(outcome("Two.", at: noon.addingTimeInterval(60),
                                                  appName: "Terminal", project: "Voice Dictation")))
        let three = try XCTUnwrap(store.add(outcome("Three.", at: noon.addingTimeInterval(120),
                                                    appName: "Terminal", project: "Voice Dictation")))
        store.setPinned(two, true)
        store.add(outcome("Other.", at: noon.addingTimeInterval(180), appName: "Notes"))
        let library = makeLibrary(store)
        library.windowOpened()
        library.selection = three.id
        let today = try XCTUnwrap(library.days.first)
        let group = try XCTUnwrap(today.groups.first { $0.place == Place(app: "Terminal", project: "Voice Dictation") })
        XCTAssertEqual(library.deletable(group.transcripts).map(\.text), ["Three.", "One."])

        library.askToDelete(group: group, on: today)
        XCTAssertEqual(library.headingDeletionToConfirm?.id, group.id)
        XCTAssertEqual(library.headingDeletionToConfirm?.title, "Delete 2 transcripts?")
        XCTAssertEqual(library.headingDeletionToConfirm?.message,
                       "Everything from Voice Dictation today, with any recordings kept for them. Pinned transcripts stay.")
        XCTAssertEqual(store.count(scope: .all), 4, "nothing goes before the yes")
        library.cancelHeadingDeletion()
        XCTAssertNil(library.headingDeletionToConfirm)
        XCTAssertEqual(store.count(scope: .all), 4)

        library.askToDelete(group: group, on: today)
        library.confirmHeadingDeletion()
        XCTAssertNil(library.headingDeletionToConfirm)
        XCTAssertEqual(store.count(scope: .all), 2)
        XCTAssertEqual(library.rows.map(\.text), ["Other.", "Two."])
        XCTAssertTrue(library.rows.contains { $0.pinned })
        XCTAssertEqual(library.selection, two.id, "the nearest remaining row takes the selection")
        XCTAssertEqual(library.count(of: .all, models: []), 2)
    }

    @MainActor
    func testAHeadingWithOnlyPinnedHasNothingToDelete() throws {
        let store = memoryStore()
        let first = try XCTUnwrap(store.add(outcome("Keep this.", at: noon, appName: "Notes")))
        let second = try XCTUnwrap(store.add(outcome("And this.", at: noon.addingTimeInterval(60), appName: "Notes")))
        store.setPinned(first, true)
        store.setPinned(second, true)
        store.add(outcome("Not pinned.", at: noon.addingTimeInterval(120), appName: "Terminal"))
        let library = makeLibrary(store)
        library.windowOpened()
        let today = try XCTUnwrap(library.days.first)
        let allPinnedGroup = try XCTUnwrap(today.groups.first { $0.place.app == "Notes" })
        XCTAssertTrue(library.deletable(allPinnedGroup.transcripts).isEmpty)

        library.askToDelete(group: allPinnedGroup, on: today)
        XCTAssertNil(library.headingDeletionToConfirm)
        library.confirmHeadingDeletion()
        XCTAssertEqual(store.count(scope: .all), 3)
    }

    @MainActor
    func testDeletingWithAFilterTakesOnlyWhatIsShown() throws {
        let store = memoryStore()
        store.add(outcome("alpha one", at: noon))
        store.add(outcome("beta", at: noon.addingTimeInterval(60)))
        store.add(outcome("alpha two", at: noon.addingTimeInterval(120)))
        let library = makeLibrary(store)
        library.windowOpened()

        library.query = "alpha"
        library.askToDelete(day: try XCTUnwrap(library.days.first))
        XCTAssertEqual(library.headingDeletionToConfirm?.title, "Delete 2 transcripts?")
        XCTAssertEqual(library.headingDeletionToConfirm?.message,
                       "The 2 shown today, with any recordings kept for them. Pinned transcripts stay.")
        library.confirmHeadingDeletion()
        library.query = ""
        XCTAssertEqual(library.rows.map(\.text), ["beta"])
    }

    /// A length filter narrows a group too; and with a place chosen, a day
    /// holds only that place's rows, so it says it takes only those shown.
    @MainActor
    func testALengthOrAPlaceSaysOnlyThoseShownGo() throws {
        let store = memoryStore()
        store.add(outcome("Quick.", at: noon, seconds: 3, appName: "Notes"))
        store.add(outcome("Slow.", at: noon.addingTimeInterval(60), seconds: 30, appName: "Notes"))
        store.add(outcome("Elsewhere.", at: noon.addingTimeInterval(120), seconds: 3, appName: "Terminal"))
        let library = makeLibrary(store)
        library.windowOpened()

        library.length = .short
        var today = try XCTUnwrap(library.days.first)
        let notes = try XCTUnwrap(today.groups.first { $0.place.app == "Notes" })
        library.askToDelete(group: notes, on: today)
        XCTAssertEqual(library.headingDeletionToConfirm?.title, "Delete 1 transcript?")
        XCTAssertEqual(library.headingDeletionToConfirm?.message,
                       "The 1 shown under Notes today, with any recordings kept for them. Pinned transcripts stay.")
        library.cancelHeadingDeletion()

        library.length = .any
        library.show(.app("Notes"))
        today = try XCTUnwrap(library.days.first)
        library.askToDelete(day: today)
        XCTAssertEqual(library.headingDeletionToConfirm?.message,
                       "The 2 shown today, with any recordings kept for them. Pinned transcripts stay.")
        library.confirmHeadingDeletion()
        XCTAssertEqual(store.search("", scope: .all).map(\.text), ["Elsewhere."])
    }

    /// Review Focus: deleting a heading while one of its transcripts is
    /// being edited or played drops the edit, rather than saving it to a
    /// deleted transcript, stops the playback, and clears its message.
    @MainActor
    func testDeletingAHeadingEndsItsEditAndPlayback() throws {
        let directory = try makeDirectory()
        let store = memoryStore(audio: AudioArchive(directory: directory.appendingPathComponent("audio", isDirectory: true)))
        let row = try XCTUnwrap(store.add(outcome("Original.", at: noon, seconds: 1,
                                                  appName: "Terminal", project: "Voice Dictation")))
        let silent = try XCTUnwrap(store.add(outcome("No recording.", at: noon.addingTimeInterval(30),
                                                     appName: "Terminal", project: "Voice Dictation")))
        let kept = try XCTUnwrap(store.add(outcome("Kept elsewhere.", at: noon.addingTimeInterval(60), appName: "Notes")))
        let library = makeLibrary(store)
        library.windowOpened()
        library.togglePlay(silent)
        XCTAssertEqual(library.message(for: silent), "Audio no longer kept")
        library.selection = row.id
        library.edit(row, text: "changed")
        let name = try XCTUnwrap(row.audioFileName)
        let recording = try XCTUnwrap(store.audio).url(for: name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path))
        // Stands in for playing it: no test plays audio.
        library.player.playing = recording
        XCTAssertTrue(library.isPlaying(row))
        let today = try XCTUnwrap(library.days.first)
        let group = try XCTUnwrap(today.groups.first { $0.transcripts.contains { $0.id == row.id } })

        library.askToDelete(group: group, on: today); library.confirmHeadingDeletion()
        library.commitEdit()   // must not crash or resurrect the transcript

        XCTAssertFalse(store.search("", scope: .all).contains { $0.text == "changed" })
        XCTAssertEqual(store.search("", scope: .all).map(\.text), ["Kept elsewhere."])
        // The selection moving on commits the edit being typed; it must find none.
        XCTAssertFalse(row.isEdited, "the edit was dropped, not saved to the deleted transcript")
        XCTAssertEqual(row.text, "Original.")
        XCTAssertFalse(library.isPlaying(row))
        XCTAssertNil(library.player.playing)
        XCTAssertNil(library.message(for: silent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.path), "its recording goes with it")
        XCTAssertEqual(library.selection, kept.id)
    }

    // MARK: - Words

    func testHeadingDeletionWords() {
        let tail = ", with any recordings kept for them. Pinned transcripts stay."
        XCTAssertTrue(LibraryModel.headingDeletionWords(count: 4, group: "Voice Dictation", dayTitle: "Today", filtered: false)
            == ("Delete 4 transcripts?", "Everything from Voice Dictation today" + tail))
        XCTAssertTrue(LibraryModel.headingDeletionWords(count: 1, group: nil, dayTitle: "Sun, Nov 15", filtered: false)
            == ("Delete 1 transcript?", "Everything dictated on Sun, Nov 15" + tail))
        XCTAssertTrue(LibraryModel.headingDeletionWords(count: 3, group: nil, dayTitle: "Yesterday", filtered: false)
            == ("Delete 3 transcripts?", "Everything dictated yesterday" + tail))
        XCTAssertTrue(LibraryModel.headingDeletionWords(count: 2, group: "Notes", dayTitle: "Sun, Nov 15", filtered: true)
            == ("Delete 2 transcripts?", "The 2 shown under Notes on Sun, Nov 15" + tail))
        XCTAssertTrue(LibraryModel.headingDeletionWords(count: 4, group: nil, dayTitle: "Today", filtered: true)
            == ("Delete 4 transcripts?", "The 4 shown today" + tail))
    }

    func testPlaceEntriesNestFoldersUnderTheirApp() {
        let entries = LibraryModel.placeEntries([
            PlaceCount(place: Place(app: "Notes", project: nil), count: 24),
            PlaceCount(place: Place(app: nil, project: nil), count: 20),
            PlaceCount(place: Place(app: "Terminal", project: "Voice Dictation"), count: 4),
            PlaceCount(place: Place(app: "Terminal", project: "Emulation"), count: 4),
            PlaceCount(place: Place(app: "Terminal", project: nil), count: 3),
            PlaceCount(place: Place(app: "Preview", project: nil), count: 1),
        ])
        XCTAssertEqual(entries.map(\.title), ["Notes", "Terminal", "Emulation", "Voice Dictation", "No folder recorded", "Preview", "Unknown app"])
        XCTAssertEqual(entries.map(\.count), [24, 11, 4, 4, 3, 1, 20])
        XCTAssertEqual(entries.map(\.isNested), [false, false, true, true, true, false, false])
        XCTAssertEqual(entries[1].filter, .app("Terminal"))
        XCTAssertEqual(entries[4].filter, .place(Place(app: "Terminal", project: nil)))
        XCTAssertEqual(entries[6].filter, .app(nil))
    }

    /// Apps tied on their total sit by name, and so do folders tied on theirs.
    func testPlaceEntriesBreakTiesByName() {
        let entries = LibraryModel.placeEntries([
            PlaceCount(place: Place(app: "Xcode", project: "Zeta"), count: 2),
            PlaceCount(place: Place(app: "Xcode", project: "Alpha"), count: 2),
            PlaceCount(place: Place(app: "Mail", project: nil), count: 4),
        ])
        XCTAssertEqual(entries.map(\.title), ["Mail", "Xcode", "Alpha", "Zeta"])
        XCTAssertEqual(entries.map(\.filter), [.app("Mail"), .app("Xcode"),
                                               .place(Place(app: "Xcode", project: "Alpha")),
                                               .place(Place(app: "Xcode", project: "Zeta"))])
    }

    /// Ruling T18-2: a pinned calendar, time zone and locale, so this holds on any Mac.
    func testRowsUnderADayShowTheTimeOfDayAndLength() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let enUS = Locale(identifier: "en_US")
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 0, minute: 52))!

        let dictated = Transcript(outcome("Hello.", at: date, seconds: 7.4))
        XCTAssertTrue(LibraryModel.rowTimes(dictated, calendar: calendar, locale: enUS) == ("12:52 AM", "7s"))

        let imported = Transcript(outcome("Hello.", at: date))
        XCTAssertEqual(imported.recordingSeconds, 0)
        XCTAssertTrue(LibraryModel.rowTimes(imported, calendar: calendar, locale: enUS) == ("12:52 AM", nil))
    }

    // MARK: - Helpers

    /// A library whose actions reach nothing real: no engines, a paster that
    /// only records, and stand-in apps.
    @MainActor
    private func makeLibrary(_ store: TranscriptStore) -> LibraryModel {
        LibraryModel(store: store, service: TranscriptionService(engines: [], selected: .appleSpeech),
                     paster: FakePaster(), system: FakeApps().system)
    }

    @MainActor
    private func memoryStore(audio: AudioArchive? = nil) -> TranscriptStore {
        // Never created: an in-memory store writes nothing.
        let unused = FileManager.default.temporaryDirectory.appendingPathComponent("vd-unused-\(UUID().uuidString)")
        let store = TranscriptStore(directory: unused, inMemory: true, audio: audio)
        XCTAssertEqual(store.health, .ok)
        return store
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vd-organisation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    /// A pasted dictation into `appName`, open on `project`, with a
    /// recording `seconds` long; no recording (0 s, as imported history)
    /// when `seconds` is 0.
    private func outcome(_ text: String, at date: Date, seconds: Double = 0, appName: String? = "TextEdit",
                         project: String? = nil, transcribeSeconds: Double = 0.2,
                         status: DictationOutcome.Status = .pasted) -> DictationOutcome {
        let clip = seconds > 0 ? AudioClip(samples: [Float](repeating: 0.1, count: Int(seconds * 16_000))) : nil
        return DictationOutcome(date: date, clip: clip, rawText: text, text: text, model: .appleSpeech,
                                transcribeSeconds: transcribeSeconds, appName: appName, project: project,
                                status: status)
    }
}
