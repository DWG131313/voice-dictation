# Mini View and Organising by Day Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the folder each dictation went into; organise the transcript list by day, then project or app, with filters and Delete on every heading; and add the mini view, a tab that sits on the edge of the window in front and shows what dictation is doing there.

**Architecture:** The project comes from the front window's `AXDocument` at paste time and is stored on `Transcript` (optional, no migration). The list stays one fetch, newest first; a pure function groups the rows into days and places, and `LibraryModel` adds a place section, a length filter, folding and heading deletion. The mini view is a new `MiniView/` folder in `VoiceDictationUI`: an Accessibility tracker reports the front window, pure functions decide the tab's face and frame, and two non-activating panels draw the tab and its click panel. `AppModel` feeds it the pipeline's work, levels and outcomes, and hides the bottom pill while the tab shows.

**Tech Stack:** Swift 6 toolchain in Swift 5 mode, SwiftUI and AppKit, SwiftData, ApplicationServices (Accessibility), XCTest.

**Spec:** `docs/superpowers/specs/2026-11-21-mini-view-and-organisation-design.md`

## Global Constraints

- Work on a branch, `mini-view-organisation`, never on `main`. Commit at the end of each task (Danny approves this by starting the plan); never push.
- Commit messages: one line, under 72 characters, ending with the attribution line the session gives.
- Run Swift as `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift …`. The suite is `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`; send long output to a file and read its tail.
- Transcript and AlternateResult: add only optional or defaulted properties.
- Prism (`DESIGN.md`): colours `bg #000`, `bg-elevated #0A0A0A`, `text #F2F2F2`, `text-muted #8C8C8C`, `hairline #2A2A2A`, spectrum `#FF2D1F #FF8A00 #FFE600 #27D14B #1E8BFF #7B3DFF`; radius 0; no shadows; Jost 600 titles, Work Sans 400/500, DM Mono. Use `Theme` in code. New tokens go into `DESIGN.md` in the same task that first uses them.
- Colour only in the tab's mark and the selected row's underline. The bottom pill and the mini view's panel stay colourless.
- Neither the tab nor its panel may activate the app or become key or main. Only the panel's Open activates it, on purpose.
- The app reads only a window's position, size, subrole, full-screen and minimised state, and its `AXDocument`. Never window titles or contents. The folder is never logged.
- No timers that poll. The tab follows macOS's notifications; the only scheduled wake-ups are a face going stale (4 s, 10 s) and Copy's "Copied" (2 s).
- Never start the microphone's engine while idle (unchanged; nothing here touches the recorder).
- Do not quit or replace the installed copy of VoiceDictation running on this Mac. Hands-on checks are Danny's.
- User-facing words, exactly: "Projects & apps", "No folder recorded", "Unknown app", "Mini View", "TRANSCRIBING", "PASTED", "COPIED", "FAILED", "Copy", "Copied", "Open", "Nothing dictated yet.", the length options "Any", "<10s", "10s–1m", ">1m".

## Review Focus

- Clicking the tab or its panel must leave the app in front in front. If VoiceDictation activates, the next paste goes to the wrong app and the tracker follows our own window. (Test in Task 9: both panels are non-activating and can never become key or main.)
- Switching apps during a dictation: the result belongs to whichever window was in front when it pasted, and Pasted shows only there. (Tests in Tasks 6 and 9.)
- Several dictations in line: the first one's outcome arrives while work is still transcribing. The tab must keep showing Transcribing, not flash Pasted. (Test in Task 6.)
- Deleting a heading while one of its transcripts is being edited or played: the edit is dropped, not saved to a deleted transcript, and playback stops. (Test in Task 4.)
- Delete with a search or length filter on removes only the rows shown under the heading, and says so. (Test in Task 4.)

---

### Task 1: Keep the folder each dictation went into

**Files:**
- Modify: `Sources/VoiceDictationLib/Pipeline/DictationState.swift` (`DictationOutcome`)
- Modify: `Sources/VoiceDictationLib/Store/Transcript.swift`
- Modify: `Sources/VoiceDictationLib/Pipeline/DictationPipeline.swift` (`Pasting`, `finish`, `report(failed:)`)
- Modify: `Sources/VoiceDictationLib/PasteEngine.swift`
- Modify: `Tests/VoiceDictationTests/Fakes.swift`, `Tests/VoiceDictationUITests/Fakes.swift` (both `FakePaster`s: `var frontmostFolder: String?`)
- Test: `Tests/VoiceDictationTests/PasteEngineTests.swift`, `DictationPipelineTests.swift`, `TranscriptStoreTests.swift`

**Interfaces:**
- Produces: `DictationOutcome.project: String?` (init parameter `project: String? = nil`, after `appName`); `Transcript.project: String?` (init parameter `project: String? = nil`, after `appName`; `Transcript(_ outcome:)` copies it); `Pasting.frontmostFolder: String? { get }` (a requirement, no default); `PasteEngine.projectName(fromDocument: String?, home: URL) -> String?` (static).

- [ ] **Step 1: Write the failing tests**

In `PasteEngineTests`:

```swift
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
```

In `DictationPipelineTests`, `testOutcomesCarryTheFrontWindowsFolder`: set `paster.frontmostFolder = "Voice Dictation"`, run one dictation to Pasted as `testHappyPathPastesAndReportsOutcome` does, and assert `outcome.project == "Voice Dictation"`. Then make the engine fail (as the existing failure tests do) and assert the failed outcome's `project == "Voice Dictation"` too.

In `TranscriptStoreTests`, `testATranscriptKeepsItsProject`: `store.add` an outcome built with `project: "Emulation"`; assert the returned transcript's `project == "Emulation"`, and that one built without it has `project == nil`.

- [ ] **Step 2: Run them and see them fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "PasteEngineTests|DictationPipelineTests|TranscriptStoreTests"`
Expected: build errors: `projectName`, `frontmostFolder` and `project` do not exist.

- [ ] **Step 3: Add the property, the requirement and the reading**

- `DictationOutcome.project` and `Transcript.project`, documented as "The folder the window was open on when the text pasted, as a project name (`PasteEngine.projectName`); nil when it had none, and for dictations from before it was kept."
- `DictationPipeline.finish`: read `paster.frontmostFolder` beside `paster.frontmostAppName`, before `paste`. `report(failed:)` reads it beside `frontmostAppName`. Neither logs it.
- `PasteEngine.frontmostFolder`: needs Accessibility (nil without it). Take the frontmost application's pid, then `AXUIElementCreateApplication`, then `kAXFocusedWindowAttribute`, then `kAXDocumentAttribute` as a `String`, then `projectName(fromDocument:home:)` with `FileManager.default.homeDirectoryForCurrentUser`.
- `projectName`: `URL(string:)`. Only a file URL with `hasDirectoryPath`. Compare paths with trailing slashes removed, and return nil for the home folder and for `/`. Otherwise return `lastPathComponent`, which is already percent-decoded.

- [ ] **Step 4: Run them and see them pass**

Run: the Step 2 command.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoiceDictationLib Tests
git commit -m "feat: keep the folder each dictation went into"
```

---

### Task 2: Places, lengths and deleting several in the store

**Files:**
- Create: `Sources/VoiceDictationLib/Store/Place.swift`
- Modify: `Sources/VoiceDictationLib/Store/TranscriptStore.swift` (`Scope`, `search`, `count`, new `places`, `delete`)
- Test: `Tests/VoiceDictationTests/TranscriptStoreTests.swift`

**Interfaces:**
- Consumes: `Transcript.project` (Task 1).
- Produces:
  ```swift
  public struct Place: Hashable, Sendable {      // app and project; "" reads as nil for both
      public let app: String?
      public let project: String?
      public init(app: String?, project: String?)
      public init(_ t: Transcript)
  }
  public enum PlaceFilter: Hashable, Sendable {
      case app(String?)      // every transcript from that app; nil: the app is unknown
      case place(Place)      // exactly that app and folder; a nil project: none recorded
      public func matches(_ t: Transcript) -> Bool
  }
  public struct PlaceCount: Equatable, Sendable { public let place: Place; public let count: Int }
  public enum LengthFilter: String, CaseIterable, Sendable {
      case any, short, medium, long  // short: 0 < s < 10; medium: 10 ≤ s < 60; long: s ≥ 60
      public func contains(_ seconds: Double) -> Bool
  }
  // TranscriptStore
  public enum Scope: Equatable, Sendable { case all, today, pinned, place(PlaceFilter) }
  public func search(_ query: String, scope: Scope, length: LengthFilter = .any) -> [Transcript]
  public func count(scope: Scope) -> Int
  public func places() -> [PlaceCount]
  public func delete(_ transcripts: [Transcript])
  ```

- [ ] **Step 1: Write the failing tests**

Give the test file's `outcome` helper `appName:`, `project:` and `seconds:` parameters. `seconds` builds the clip as `AudioClip(samples: [Float](repeating: 0.1, count: Int(seconds * 16_000)))`.

```swift
@MainActor func testSearchByPlace() {
    // Terminal/Voice Dictation ×2, Terminal/nil ×1, Notes/nil ×1, nil/nil ×1
    XCTAssertEqual(store.search("", scope: .place(.app("Terminal"))).count, 3)
    XCTAssertEqual(store.search("", scope: .place(.place(Place(app: "Terminal", project: "Voice Dictation")))).count, 2)
    XCTAssertEqual(store.search("", scope: .place(.place(Place(app: "Terminal", project: nil)))).count, 1)
    XCTAssertEqual(store.search("", scope: .place(.app(nil))).count, 1)
    XCTAssertEqual(store.count(scope: .place(.app("Terminal"))), 3)
}

@MainActor func testLengthFilterBoundaries() {
    // seconds 0 (no clip), 9.9, 10, 59.9, 60
    XCTAssertEqual(store.search("", scope: .all, length: .any).count, 5)
    XCTAssertEqual(store.search("", scope: .all, length: .short).map(\.recordingSeconds), [9.9])
    XCTAssertEqual(Set(store.search("", scope: .all, length: .medium).map(\.recordingSeconds)), [10, 59.9])
    XCTAssertEqual(store.search("", scope: .all, length: .long).map(\.recordingSeconds), [60])
}

@MainActor func testPlacesCountsEachAppAndFolderMostFirst() {
    // the testSearchByPlace transcripts
    XCTAssertEqual(store.places(), [
        PlaceCount(place: Place(app: "Terminal", project: "Voice Dictation"), count: 2),
        PlaceCount(place: Place(app: "Notes", project: nil), count: 1),
        PlaceCount(place: Place(app: "Terminal", project: nil), count: 1),
        PlaceCount(place: Place(app: nil, project: nil), count: 1),
    ])  // ties: app by name, unknown app last; then project by name, none last
}

@MainActor func testDeletingSeveralRemovesThemAndTheirRecordings() throws {
    // a store with an AudioArchive in makeDirectory(); three outcomes with clips
    store.delete([first, second])
    XCTAssertEqual(store.search("", scope: .all).map(\.id), [third.id])
    XCTAssertEqual(audio.fileNames().count, 1)
}
```

Use test-local `PlaceCount(place:count:)` construction (give `PlaceCount` a public memberwise init).

- [ ] **Step 2: Run them and see them fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TranscriptStoreTests`
Expected: build errors: `Place`, `PlaceFilter`, `LengthFilter`, `places()` and `delete(_:[Transcript])` do not exist.

- [ ] **Step 3: Implement**

- `search` keeps its predicate for the date, pinned and text. The place filter and length apply in memory after the fetch, which avoids SwiftData's optional-predicate pitfalls.
- `count(scope:)` for `.place` counts in memory. The other scopes keep `fetchCount`.
- `places()` fetches all transcripts and groups them by `Place(_:)`.
- `delete(_:)` makes one save, then removes the recordings, and only after a successful save. The single `delete(_ t:)` becomes `delete([t])`.

- [ ] **Step 4: Run them and see them pass**

Run: the Step 2 command.
Expected: PASS, the existing store tests included.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoiceDictationLib/Store Tests/VoiceDictationTests/TranscriptStoreTests.swift
git commit -m "feat: find transcripts by place and length; delete several"
```

---

### Task 3: Grouping rows into days and places

**Files:**
- Create: `Sources/VoiceDictationUI/Window/TranscriptGroups.swift`
- Test: `Tests/VoiceDictationUITests/TranscriptGroupsTests.swift`

**Interfaces:**
- Consumes: `Place`, `Place(_ t: Transcript)` (Task 2).
- Produces:
  ```swift
  struct PlaceGroup: Identifiable { let place: Place; let transcripts: [Transcript]; let id: String }  // id: "\(day id)|\(app ?? "")|\(project ?? "")"
  struct DayGroup: Identifiable { let day: Date; let groups: [PlaceGroup]; let id: String           // id: "day-YYYY-MM-DD" in the calendar
                                  var transcripts: [Transcript] { groups.flatMap(\.transcripts) } }
  enum TranscriptGroups {
      static func days(_ rows: [Transcript], calendar: Calendar = .current) -> [DayGroup]   // rows newest first
      static func dayTitle(_ day: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String
      static func title(of place: Place) -> (name: String, app: String?)
  }
  ```

- [ ] **Step 1: Write the failing tests**

Build the transcripts with `Transcript(date:text:rawText:appName:project:modelKey:recordingSeconds:transcribeSeconds:statusRaw:)`. Use a calendar in `America/Los_Angeles` and the `en_US` locale. Take `now` as 2026-11-21 12:00 there.

```swift
func testDaysSplitAtMidnightInTheCalendarsTimeZone() {
    // 23:59 on Nov 20 and 00:01 on Nov 21, Los Angeles time
    let days = TranscriptGroups.days([at0001, at2359], calendar: la)
    XCTAssertEqual(days.map { $0.transcripts.map(\.id) }, [[at0001.id], [at2359.id]])
}

func testGroupsAreOrderedByTheirNewestTranscript() {
    // Notes 10:10, Terminal/Voice Dictation 10:05, Notes 10:00, given newest first
    let day = try XCTUnwrap(TranscriptGroups.days([notes1010, vd1005, notes1000], calendar: la).first)
    XCTAssertEqual(day.groups.map(\.place), [Place(app: "Notes", project: nil), Place(app: "Terminal", project: "Voice Dictation")])
    XCTAssertEqual(day.groups[0].transcripts.map(\.id), [notes1010.id, notes1000.id])
}

func testAFolderInTwoAppsIsTwoGroups() { /* Terminal/X and Code/X on one day → 2 groups */ }

func testUnknownAppsGroupTogether() {
    // appName nil and appName "" on one day → 1 group
    XCTAssertEqual(TranscriptGroups.title(of: Place(app: nil, project: nil)).name, "Unknown app")
}

func testDayTitles() {
    XCTAssertEqual(TranscriptGroups.dayTitle(nov21, now: now, calendar: la, locale: enUS), "Today")
    XCTAssertEqual(TranscriptGroups.dayTitle(nov20, now: now, calendar: la, locale: enUS), "Yesterday")
    XCTAssertEqual(TranscriptGroups.dayTitle(nov15, now: now, calendar: la, locale: enUS), "Sun, Nov 15")
    XCTAssertEqual(TranscriptGroups.dayTitle(nov15of2025, now: now, calendar: la, locale: enUS), "Sat, Nov 15, 2025")
}

func testGroupTitles() {
    XCTAssertTrue(TranscriptGroups.title(of: Place(app: "Terminal", project: "Voice Dictation")) == ("Voice Dictation", "Terminal"))
    XCTAssertTrue(TranscriptGroups.title(of: Place(app: "Notes", project: nil)) == ("Notes", nil))
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TranscriptGroupsTests`
Expected: build errors: `TranscriptGroups` does not exist.

- [ ] **Step 3: Implement `TranscriptGroups`**

- `dayTitle` uses `Date.FormatStyle(locale:calendar:timeZone:)` with `.weekday(.abbreviated).month(.abbreviated).day()`, plus `.year()` when the year isn't `now`'s. The relative words come first, as `LibraryModel.whenString` does it.
- Groups take their order from where their first (newest) row appears.

- [ ] **Step 4: Run them and see them pass**

Run: the Step 2 command.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoiceDictationUI/Window/TranscriptGroups.swift Tests/VoiceDictationUITests/TranscriptGroupsTests.swift
git commit -m "feat: group transcripts by day, then project or app"
```

---

### Task 4: The library: places, length, folding and deleting a heading

**Files:**
- Modify: `Sources/VoiceDictationUI/Window/LibraryModel.swift`
- Test: `Tests/VoiceDictationUITests/LibraryOrganisationTests.swift` (new; copy `LibraryModelTests`' `memoryStore`, `makeLibrary` and `outcome` helpers, with `appName`, `project` and `seconds` added)

**Interfaces:**
- Consumes: `Scope.place`, `LengthFilter`, `PlaceFilter`, `PlaceCount`, `store.places()`, `store.delete([Transcript])` (Task 2); `TranscriptGroups`, `DayGroup`, `PlaceGroup` (Task 3).
- Produces (on `LibraryModel`):
  ```swift
  // Section gains `case places` (title "Projects & apps"); `Section.transcripts` stays [.all, .today, .pinned].
  public private(set) var place: PlaceFilter?
  public var length: LengthFilter = .any                       // didSet lists again
  public private(set) var days: [DayGroup] = []                // set with `rows`
  var scope: TranscriptStore.Scope?                            // .place(place) for .places, else section.scope
  var showsGroupHeadings: Bool                                 // false only for .places with a `.place(_)` filter
  public func show(_ filter: PlaceFilter)                      // section = .places, closes the panel, lists
  public var isPlacesPanelOpen: Bool                           // opening it reads `placeEntries`
  private(set) var placeEntries: [PlaceEntry] = []
  var placeTitle: String?                                      // the chosen place's name, for the sidebar
  func toggleFold(_ headingID: String)
  func isFolded(_ headingID: String) -> Bool
  var visibleRows: [Transcript]                                // rows not under a folded day or group
  func deletable(_ transcripts: [Transcript]) -> [Transcript]  // the unpinned
  public private(set) var headingDeletionToConfirm: HeadingDeletion?
  func askToDelete(day: DayGroup)
  func askToDelete(group: PlaceGroup, on day: DayGroup)
  public func confirmHeadingDeletion()
  public func cancelHeadingDeletion()
  nonisolated static func placeEntries(_ counts: [PlaceCount]) -> [PlaceEntry]
  nonisolated static func headingDeletionWords(count: Int, group: String?, dayTitle: String, filtered: Bool) -> (title: String, message: String)
  nonisolated static func rowTimes(_ t: Transcript, calendar: Calendar = .current, locale: Locale = .current) -> (time: String, length: String?)

  struct PlaceEntry: Identifiable, Equatable { let filter: PlaceFilter; let title: String; let count: Int; let isNested: Bool; var id: PlaceFilter { filter } }
  public struct HeadingDeletion: Identifiable, Equatable { public let id: String; let ids: [Transcript.ID]; let title: String; let message: String }
  ```
  `windowOpened`, `listRows` and `MainWindow` use `scope` where they used `section.scope`.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor func testChoosingAPlaceListsItAcrossDays() {
    // Terminal/Voice Dictation on two days, Notes on one
    library.isPlacesPanelOpen = true
    library.show(.place(Place(app: "Terminal", project: "Voice Dictation")))
    XCTAssertEqual(library.section, .places)
    XCTAssertFalse(library.isPlacesPanelOpen)
    XCTAssertEqual(library.days.count, 2)
    XCTAssertTrue(library.rows.allSatisfy { $0.project == "Voice Dictation" })
    XCTAssertFalse(library.showsGroupHeadings)
    library.show(.app("Terminal"))
    XCTAssertTrue(library.showsGroupHeadings)
    XCTAssertEqual(library.placeTitle, "Terminal")
}

@MainActor func testLengthNarrowsTheList() {
    library.length = .short
    XCTAssertTrue(library.rows.allSatisfy { $0.recordingSeconds > 0 && $0.recordingSeconds < 10 })
}

@MainActor func testFoldingHidesRowsFromTheKeyboard() {
    // one day, groups A (2 rows) then B (1 row); select A's first row
    library.toggleFold(groupB.id)
    library.moveSelection(by: 1); library.moveSelection(by: 1)
    XCTAssertEqual(library.selection, a2.id, "stops at the last visible row")
    library.toggleFold(groupA.id)   // the selected row folds away
    XCTAssertNil(library.selection, "nothing visible is left")
    library.toggleFold(groupB.id)
    library.toggleFold(groupA.id)
    library.selection = a1.id
    library.toggleFold(groupA.id)
    XCTAssertEqual(library.selection, b1.id, "the nearest visible row")
    library.askToDelete(day: today)
    XCTAssertEqual(library.headingDeletionToConfirm?.ids.count, 3, "a folded group's rows are still under the day")
}

@MainActor func testDeletingAGroupAsksFirstAndKeepsPinned() {
    // a group of 3 today, one pinned; another group of 1
    library.askToDelete(group: group, on: today)
    XCTAssertEqual(library.headingDeletionToConfirm?.title, "Delete 2 transcripts?")
    XCTAssertEqual(store.count(scope: .all), 4, "nothing goes before the yes")
    library.cancelHeadingDeletion()
    XCTAssertNil(library.headingDeletionToConfirm)
    library.askToDelete(group: group, on: today)
    library.confirmHeadingDeletion()
    XCTAssertEqual(store.count(scope: .all), 2)
    XCTAssertTrue(library.rows.contains { $0.pinned })
}

@MainActor func testAHeadingWithOnlyPinnedHasNothingToDelete() {
    library.askToDelete(group: allPinnedGroup, on: today)
    XCTAssertNil(library.headingDeletionToConfirm)
}

@MainActor func testDeletingWithAFilterTakesOnlyWhatIsShown() {
    // today: "alpha one", "alpha two", "beta"; query "alpha"
    library.query = "alpha"
    library.askToDelete(day: try XCTUnwrap(library.days.first))
    XCTAssertEqual(library.headingDeletionToConfirm?.message,
                   "The 2 shown today, with any recordings kept for them. Pinned transcripts stay.")
    library.confirmHeadingDeletion()
    library.query = ""
    XCTAssertEqual(library.rows.map(\.text), ["beta"])
}

@MainActor func testDeletingAHeadingEndsItsEditAndPlayback() {
    // select a row under the group, edit(_:text:) without committing, then delete the group
    library.edit(row, text: "changed")
    library.askToDelete(group: group, on: today); library.confirmHeadingDeletion()
    library.commitEdit()   // must not crash or resurrect the transcript
    XCTAssertFalse(store.search("", scope: .all).contains { $0.text == "changed" })
    XCTAssertFalse(library.isPlaying(row))
}

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

func testRowsUnderADayShowTheTimeOfDayAndLength() {
    // 12:52 AM, 7.4 s, en_US: ("12:52 AM", "7s"); imported (0 s): ("12:52 AM", nil)
}
```

Ordering rules for `placeEntries`: apps by their total, most first, with ties by name. Unknown app comes last. Within an app, folders by count, ties by name, then "No folder recorded". An app with no folders is one line. Day phrases for the words: "Today" becomes "today", "Yesterday" becomes "yesterday", and any other title becomes "on <title>". A day heading says "Everything dictated <phrase>"; a group heading says "Everything from <group> <phrase>". When filtered, a day says "The <n> shown <phrase>" and a group says "The <n> shown under <group> <phrase>".

- [ ] **Step 2: Run them and see them fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "LibraryOrganisationTests|LibraryModelTests"`
Expected: build errors for the new members.

- [ ] **Step 3: Implement**

- `moveSelection(by:)` walks `visibleRows`.
- `toggleFold` moves a selection it hid with `neighbour(of:before:after:)` over the visible ids before and after the fold.
- `confirmHeadingDeletion` does what `delete(_:confirmed:)` does for each transcript: drop its draft, stop its playback, clear its message. Then it calls `store.delete(_:)` once and relists with `neighbour`.
- `emptyMessage` adds "No transcripts of that length." when the length isn't `.any` and there is no query.
- `count(of: .places, …)` is nil.

- [ ] **Step 4: Run them and see them pass**

Run: the Step 2 command.
Expected: PASS, the existing `LibraryModelTests` included.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoiceDictationUI/Window/LibraryModel.swift Tests/VoiceDictationUITests/LibraryOrganisationTests.swift
git commit -m "feat: places, length, folding and heading delete in the library"
```

---

### Task 5: The list's headings, the Length row and the Projects & apps panel

**Files:**
- Modify: `Sources/VoiceDictationUI/Window/TranscriptList.swift` (rows grouped; `TranscriptRow` shows `rowTimes`, indented 34 pt)
- Modify: `Sources/VoiceDictationUI/Window/Sidebar.swift`
- Modify: `Sources/VoiceDictationUI/Window/MainWindow.swift` (use `library.scope`; the panel overlay)
- Create: `Sources/VoiceDictationUI/Window/ListHeadings.swift` (`DayHeading`, `GroupHeading`, `DeleteHeadingButton`)
- Create: `Sources/VoiceDictationUI/Window/PlacesPanel.swift`
- Modify: `DESIGN.md` (components `day-heading`, `group-heading`, `places-panel`; a line each under Components)

**Interfaces:**
- Consumes: Task 4's `days`, `showsGroupHeadings`, `toggleFold`, `isFolded`, `deletable`, `askToDelete`, `headingDeletionToConfirm`, `confirmHeadingDeletion`, `cancelHeadingDeletion`, `length`, `isPlacesPanelOpen`, `placeEntries`, `show(_:)`, `placeTitle`, `rowTimes`; `TranscriptGroups.dayTitle`, `title(of:)`.

- [ ] **Step 1: Build the views to the spec**

Follow `docs/superpowers/mockups/2026-11-21-organise-by-day.png` and the spec's Part 2 and Part 3. The numbers:
- **Day heading:** `bg-elevated` with a hairline below. The title in Work Sans 500 11, tracking 0.9, upper case, text colour. The count in DM Mono 12, muted.
- **Group heading:** a chevron "▾"/"▸" in DM Mono 10, muted. The name in Work Sans 500 13. The app and count in DM Mono 12, muted ("Terminal · 4", or just "24").
- **Delete:** Work Sans 12, muted, text colour on hover. Shown only when `deletable` isn't empty. Tapping the rest of a heading folds it.
- **Length row:** sits under search. "LENGTH" as a label, then "Any", "<10s", "10s–1m", ">1m" in DM Mono 12, the chosen one in text colour with a 1 pt underline. A hairline below.
- **Confirmation:** `.confirmationDialog` on `headingDeletionToConfirm`, with its title and message, and the buttons "Delete" (destructive) and "Cancel".
- **Sidebar:** a "Projects & apps" line with "›" after Pinned. Tapping it toggles the panel. While `section == .places` the line is in text colour, with `placeTitle` under it in DM Mono 11, muted.
- **Places panel:** 240 pt wide, against the sidebar's right edge, `bg-elevated` with hairline sides. The heading "PROJECTS & APPS" sits in the label style, text colour. Entries have counts in DM Mono 12, muted; nested ones are indented 16 pt more. To the right of the panel, `bg` at 0.55 opacity covers the columns; tapping it closes the panel. Esc closes it too.

- [ ] **Step 2: Build and run the suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -5` and then the full suite.
Expected: `Build complete!`; all tests pass.

- [ ] **Step 3: Lint the design manifest**

Run: `npx --yes @google/design.md lint DESIGN.md`
Expected: no errors. If npx can't fetch the package offline, note it in the ledger and move on.

- [ ] **Step 4: Commit**

```bash
git add Sources/VoiceDictationUI/Window DESIGN.md
git commit -m "feat: list by day with headings, length row and places panel"
```

---

### Task 6: The tab's line and face

**Files:**
- Modify: `Sources/VoiceDictationUI/Indicator/LevelLine.swift`
- Create: `Sources/VoiceDictationUI/MiniView/FrontWindow.swift`
- Create: `Sources/VoiceDictationUI/MiniView/MiniTab.swift`
- Test: `Tests/VoiceDictationUITests/LevelLineTests.swift`, `Tests/VoiceDictationUITests/MiniTabTests.swift`

**Interfaces:**
- Produces:
  ```swift
  // LevelLine
  public struct Geometry: Equatable, Sendable { public let width: CGFloat; public let height: CGFloat; public let step: CGFloat }
  public static let indicator: Geometry   // 170, 26, 5 — LevelLine.width/height/step stay the indicator's
  public static let tab: Geometry         // 26, 18, 2.6
  public let geometry: Geometry
  public init(_ geometry: Geometry = .indicator)   // reset() keeps the geometry

  // FrontWindow.swift
  struct WindowIdentity: Hashable { init(pid: pid_t, token: AnyHashable) }   // equal for the same window
  struct FrontWindow: Equatable { let id: WindowIdentity; let frame: CGRect; let visibleFrame: CGRect }  // AppKit coordinates

  // MiniTab.swift
  enum MiniTabMark: Equatable { case restLine, liveSpectrum, flatSpectrum, split }
  struct MiniTabFace: Equatable { var mark: MiniTabMark; var time: String? = nil; var timeIsMuted = false
                                  var word: String? = nil; var wordIsMuted = false; var showsClipboard = false }
  struct MiniTabResult: Equatable { let status: DictationOutcome.Status; let dictated: Date; let arrived: Date; let window: WindowIdentity? }
  enum MiniTab {
      static let pastedSeconds: TimeInterval = 4, copiedSeconds: TimeInterval = 10, failedSeconds: TimeInterval = 4
      static func face(work: DictationState, result: MiniTabResult?, window: WindowIdentity?, now: Date,
                       calendar: Calendar = .current, locale: Locale = .current) -> MiniTabFace
      static func nextChange(result: MiniTabResult?, now: Date) -> Date?
      static func clockTime(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String?
  }
  ```

- [ ] **Step 1: Write the failing tests**

`LevelLineTests.testTheTabsLineSpansTheTabAndStaysInside`: feed `LevelLine(.tab)` a peak of 0.5 every 50 ms for 1 s. At the last time, the points' last `x` is ≥ 26, the count is ≤ 13 (`Int(26 / 2.6) + 3`), and every `y` is in `1...17`.

`MiniTabTests` (en_US, Los Angeles, `t` = 2026-11-21 00:52, `here = WindowIdentity(pid: 1, token: 1)`, `there = WindowIdentity(pid: 1, token: 2)`):

```swift
XCTAssertEqual(MiniTab.face(work: .recording(since: t), result: nil, window: here, now: t + 4.2, …),
               MiniTabFace(mark: .liveSpectrum, time: "0:04"))
XCTAssertEqual(MiniTab.face(work: .transcribing, result: nil, window: here, now: t, …),
               MiniTabFace(mark: .flatSpectrum, word: "TRANSCRIBING", wordIsMuted: true))
XCTAssertEqual(MiniTab.face(work: .cleaning, …).mark, .flatSpectrum)
let pasted = MiniTabResult(status: .pasted, dictated: t, arrived: t, window: here)
XCTAssertEqual(MiniTab.face(work: .idle, result: pasted, window: here, now: t + 1, …),
               MiniTabFace(mark: .split, time: "12:52", word: "PASTED"))
XCTAssertEqual(MiniTab.face(work: .transcribing, result: pasted, window: here, now: t + 1, …).mark,
               .flatSpectrum, "a dictation still in line keeps the tab working")
XCTAssertEqual(MiniTab.face(work: .idle, result: pasted, window: here, now: t + 5, …),
               MiniTabFace(mark: .restLine, time: "12:52", timeIsMuted: true))
XCTAssertEqual(MiniTab.face(work: .idle, result: pasted, window: there, now: t + 1, …),
               MiniTabFace(mark: .restLine), "another window shows just the line")
let copied = MiniTabResult(status: .copied, dictated: t, arrived: t, window: here)
XCTAssertEqual(MiniTab.face(work: .idle, result: copied, window: here, now: t + 9, …),
               MiniTabFace(mark: .restLine, time: "12:52", word: "COPIED", showsClipboard: true))
XCTAssertEqual(MiniTab.face(work: .idle, result: copied, window: here, now: t + 11, …).word, nil)
let failed = MiniTabResult(status: .failed, dictated: t, arrived: t, window: here)
XCTAssertEqual(MiniTab.face(work: .idle, result: failed, window: here, now: t + 1, …),
               MiniTabFace(mark: .restLine, time: "12:52", word: "FAILED", wordIsMuted: true))
let yesterday = MiniTabResult(status: .pasted, dictated: t - 86_400, arrived: t - 86_400, window: here)
XCTAssertEqual(MiniTab.face(work: .idle, result: yesterday, window: here, now: t, …), MiniTabFace(mark: .restLine))
XCTAssertEqual(MiniTab.face(work: .idle, result: nil, window: nil, now: t, …), MiniTabFace(mark: .restLine))
XCTAssertEqual(MiniTab.nextChange(result: pasted, now: t + 1), t + 4)
XCTAssertEqual(MiniTab.nextChange(result: copied, now: t + 1), t + 10)
XCTAssertNil(MiniTab.nextChange(result: pasted, now: t + 5))
```

Any state other than recording, transcribing or cleaning reads as idle.

- [ ] **Step 2: Run them and see them fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "LevelLineTests|MiniTabTests"`
Expected: build errors for `LevelLine(.tab)` and `MiniTab`.

- [ ] **Step 3: Implement**

- LevelLine's capacity becomes per instance: `Int(geometry.width / geometry.step) + 3`. `points(at:)` uses `geometry`. The existing statics and tests are unchanged.
- The recording time uses `IndicatorView.clock`.
- `clockTime` uses `.hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits)` for a date in `now`'s day, and gives nil otherwise.

- [ ] **Step 4: Run them and see them pass**

Run: the Step 2 command.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoiceDictationUI/Indicator/LevelLine.swift Sources/VoiceDictationUI/MiniView Tests/VoiceDictationUITests
git commit -m "feat: the mini view tab's line and face"
```

---

### Task 7: Where the tab and its panel go

**Files:**
- Create: `Sources/VoiceDictationUI/MiniView/MiniViewLayout.swift`
- Test: `Tests/VoiceDictationUITests/MiniViewLayoutTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum MiniViewSide: Equatable { case right, left }
  enum MiniViewLayout {
      static let tabWidth: CGFloat = 40
      static let topInset: CGFloat = 40
      static func tabFrame(window: CGRect, side: MiniViewSide, tabHeight: CGFloat, visibleFrame: CGRect) -> CGRect
      static func panelFrame(tab: CGRect, window: CGRect, panelSize: CGSize, visibleFrame: CGRect) -> CGRect
      static func side(droppedAt midX: CGFloat, window: CGRect) -> MiniViewSide
      static func appKitFrame(axPosition: CGPoint, axSize: CGSize, primaryScreenHeight: CGFloat) -> CGRect
  }
  ```

- [ ] **Step 1: Write the failing tests**

All the rects are AppKit's: y goes up. `screen = CGRect(x: 0, y: 0, width: 1440, height: 875)`, tab height 150.

```swift
XCTAssertEqual(MiniViewLayout.tabFrame(window: CGRect(x: 100, y: 100, width: 800, height: 600), side: .right, tabHeight: 150, visibleFrame: screen),
               CGRect(x: 900, y: 510, width: 40, height: 150))
XCTAssertEqual(MiniViewLayout.tabFrame(window: CGRect(x: 100, y: 100, width: 800, height: 600), side: .left, tabHeight: 150, visibleFrame: screen),
               CGRect(x: 60, y: 510, width: 40, height: 150))
// No room on the right: the left.
XCTAssertEqual(MiniViewLayout.tabFrame(window: CGRect(x: 600, y: 100, width: 820, height: 600), side: .right, tabHeight: 150, visibleFrame: screen).maxX, 600)
// No room either side: just inside, on the chosen side.
XCTAssertEqual(MiniViewLayout.tabFrame(window: CGRect(x: 10, y: 100, width: 1420, height: 600), side: .right, tabHeight: 150, visibleFrame: screen).maxX, 1430)
XCTAssertEqual(MiniViewLayout.tabFrame(window: CGRect(x: 10, y: 100, width: 1420, height: 600), side: .left, tabHeight: 150, visibleFrame: screen).minX, 10)
// Never below the screen.
XCTAssertGreaterThanOrEqual(MiniViewLayout.tabFrame(window: CGRect(x: 100, y: 0, width: 800, height: 120), side: .right, tabHeight: 150, visibleFrame: screen).minY, 0)
// A second screen to the right.
XCTAssertEqual(MiniViewLayout.tabFrame(window: CGRect(x: 2000, y: 200, width: 800, height: 600), side: .right, tabHeight: 150,
               visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055)).minX, 2800)
// The panel: beyond the tab when it fits, else over the window beside it; tops aligned.
let tab = CGRect(x: 900, y: 510, width: 40, height: 150)
XCTAssertEqual(MiniViewLayout.panelFrame(tab: tab, window: CGRect(x: 100, y: 100, width: 800, height: 600), panelSize: CGSize(width: 248, height: 180), visibleFrame: screen),
               CGRect(x: 940, y: 480, width: 248, height: 180))
let edgeTab = CGRect(x: 1300, y: 510, width: 40, height: 150)
XCTAssertEqual(MiniViewLayout.panelFrame(tab: edgeTab, window: CGRect(x: 500, y: 100, width: 800, height: 600), panelSize: CGSize(width: 248, height: 180), visibleFrame: screen).maxX, 1300)
XCTAssertEqual(MiniViewLayout.side(droppedAt: 801, window: CGRect(x: 100, y: 100, width: 1400, height: 600)), .right)
XCTAssertEqual(MiniViewLayout.side(droppedAt: 799, window: CGRect(x: 100, y: 100, width: 1400, height: 600)), .left)
XCTAssertEqual(MiniViewLayout.appKitFrame(axPosition: CGPoint(x: 100, y: 50), axSize: CGSize(width: 800, height: 600), primaryScreenHeight: 900),
               CGRect(x: 100, y: 250, width: 800, height: 600))
```

- [ ] **Step 2: Run them and see them fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MiniViewLayoutTests`
Expected: build errors: `MiniViewLayout` does not exist.

- [ ] **Step 3: Implement `MiniViewLayout`**

- **The tab's top:** `window.maxY - topInset`. It then moves up as far as needed to keep `minY ≥ visibleFrame.minY`.
- **"Room":** the tab stays inside `visibleFrame` horizontally.
- **The panel:** it goes on the far side of the tab from the window, and is mirrored over the window when it doesn't fit. It's kept inside `visibleFrame`.

- [ ] **Step 4: Run them and see them pass**

Run: the Step 2 command.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoiceDictationUI/MiniView/MiniViewLayout.swift Tests/VoiceDictationUITests/MiniViewLayoutTests.swift
git commit -m "feat: where the mini view tab and panel go"
```

---

### Task 8: Following the front window

**Files:**
- Create: `Sources/VoiceDictationUI/MiniView/FrontWindowTracker.swift`
- Test: `Tests/VoiceDictationUITests/FrontWindowTrackerTests.swift`

**Interfaces:**
- Consumes: `FrontWindow`, `WindowIdentity` (Task 6); `MiniViewLayout.appKitFrame` (Task 7).
- Produces:
  ```swift
  @MainActor protocol FrontWindowWatching: AnyObject {
      var onChange: ((FrontWindow?) -> Void)? { get set }   // after every change, nil when the tab may not show
      var current: FrontWindow? { get }
      func start()
      func stop()
  }
  @MainActor final class FrontWindowTracker: FrontWindowWatching {
      init()
      nonisolated static func shows(subrole: String?, isFullScreen: Bool, isMinimized: Bool, isOwnApp: Bool) -> Bool
  }
  ```

- [ ] **Step 1: Write the failing test**

```swift
func testTheTabSitsOnlyOnOrdinaryWindowsOfOtherApps() {
    XCTAssertTrue(FrontWindowTracker.shows(subrole: "AXStandardWindow", isFullScreen: false, isMinimized: false, isOwnApp: false))
    XCTAssertFalse(FrontWindowTracker.shows(subrole: "AXStandardWindow", isFullScreen: true, isMinimized: false, isOwnApp: false))
    XCTAssertFalse(FrontWindowTracker.shows(subrole: "AXStandardWindow", isFullScreen: false, isMinimized: true, isOwnApp: false))
    XCTAssertFalse(FrontWindowTracker.shows(subrole: "AXStandardWindow", isFullScreen: false, isMinimized: false, isOwnApp: true))
    XCTAssertFalse(FrontWindowTracker.shows(subrole: "AXDialog", isFullScreen: false, isMinimized: false, isOwnApp: false))
    XCTAssertFalse(FrontWindowTracker.shows(subrole: nil, isFullScreen: false, isMinimized: false, isOwnApp: false))
}
```

- [ ] **Step 2: Run it and see it fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FrontWindowTrackerTests`
Expected: build error: `FrontWindowTracker` does not exist.

- [ ] **Step 3: Implement the tracker**

- `start()` observes `NSWorkspace.didActivateApplicationNotification` and reads the frontmost app at once. `stop()` removes everything.
- For the front app's pid, create one `AXObserver`. Add `kAXFocusedWindowChangedNotification` on the app element. On the focused window add `kAXMovedNotification`, `kAXResizedNotification`, `kAXUIElementDestroyedNotification` and `kAXWindowMiniaturizedNotification`. Add the run loop source to the main run loop. Remove the window's notifications when focus moves, and the observer when the app changes.
- On each notification, re-read `kAXSubroleAttribute`, `"AXFullScreen"`, `kAXMinimizedAttribute`, `kAXPositionAttribute` and `kAXSizeAttribute`.
- Build the frame with `appKitFrame(…, primaryScreenHeight: NSScreen.screens[0].frame.height)`. `visibleFrame` comes from the screen containing the frame's centre, or the first screen.
- The identity token is a small `Hashable` box around the `AXUIElement`, using `CFEqual` and `CFHash`.
- Set `current`, then call `onChange`. Without Accessibility (`AXIsProcessTrusted()` false), `current` stays nil.

- [ ] **Step 4: Run it and see it pass; then verify the notifications for real**

Run: the Step 2 command.
Expected: PASS.

Then check the spec's first "verify early" item with a scratch script, which you don't commit. Put it in the session scratchpad, not the repo.
- The script registers the same observer for Terminal's focused window, and prints each notification for 15 seconds.
- Meanwhile it moves that window 10 pt right and then back, by setting `kAXPositionAttribute`.

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift <scratchpad>/observe.swift`
Expected: at least two `AXMoved` lines. If none arrive, stop and record it as a ruling: the tracker then needs another trigger, and the plan's no-polling rule needs Danny.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoiceDictationUI/MiniView/FrontWindowTracker.swift Tests/VoiceDictationUITests/FrontWindowTrackerTests.swift
git commit -m "feat: follow the front window through Accessibility"
```

---

### Task 9: The mini view on screen, wired into the app

**Files:**
- Create: `Sources/VoiceDictationUI/MiniView/MiniTabView.swift` (the marks, time and word)
- Create: `Sources/VoiceDictationUI/MiniView/MiniPanelView.swift` (the click panel's content)
- Create: `Sources/VoiceDictationUI/MiniView/MiniViewWindows.swift` (`MiniTabPanel`, `MiniInfoPanel`)
- Create: `Sources/VoiceDictationUI/MiniView/MiniViewController.swift`
- Modify: `Sources/VoiceDictationLib/PreferencesManager.swift` (`miniViewEnabled`, `miniViewOnLeft`)
- Modify: `Sources/VoiceDictationUI/AppModel.swift`
- Modify: `Sources/VoiceDictationUI/MenuBar/MenuBarContent.swift`
- Modify: `DESIGN.md` (typography `mono-small` DM Mono 10, `label-small` Work Sans 500 9 tracking 0.8; components `mini-tab`, `mini-panel`; the Colours, Components and Do's and Don'ts lines the spec's "Design system changes" names)
- Modify: `CLAUDE.md` (Architecture: a `MiniView` line; Known Constraints: what the mini view reads)
- Modify: `Tests/VoiceDictationUITests/Fakes.swift` (`FakeMiniView`, `FakeWindowWatcher`)
- Test: `Tests/VoiceDictationUITests/MiniViewControllerTests.swift`, `AppModelTests.swift`, `IndicatorPanelTests.swift` (beside it, the panels' focus test)

**Interfaces:**
- Consumes: everything from Tasks 6–8; `store.latest`, `library.copy(_:)`, `AppModel.requestMainWindow()`.
- Produces:
  ```swift
  @MainActor protocol MiniViewPresenting: AnyObject {
      var isShowingTab: Bool { get }
      var onTabShownOrHidden: (() -> Void)? { get set }
      func connect(latest: @escaping () -> Transcript?, copy: @escaping (Transcript) -> Void, openMainWindow: @escaping () -> Void)
      func setEnabled(_ enabled: Bool)
      func workChanged(_ work: DictationState)
      func heard(peak: Float, at time: TimeInterval)
      func finished(_ outcome: DictationOutcome)
  }
  @MainActor final class MiniViewController: MiniViewPresenting {
      init(tracker: FrontWindowWatching, preferences: PreferencesManager, showsWindows: Bool = true)
      func copyLatest()                       // the panel's Copy
      func dropped(atMidX x: CGFloat)         // the end of a drag; saves the side
      private(set) var result: MiniTabResult?
  }
  // PreferencesManager: public var miniViewEnabled: Bool (default false), public var miniViewOnLeft: Bool (default false)
  // AppModel: init(…, miniView: MiniViewPresenting? = nil); public var miniViewEnabled: Bool { get set }
  ```

- [ ] **Step 1: Write the failing tests**

Fakes: `FakeWindowWatcher: FrontWindowWatching` with `send(_ window: FrontWindow?)`, which sets `current` and calls `onChange`. `FakeMiniView: MiniViewPresenting` with a settable `isShowingTab` and records: `works: [DictationState]`, `outcomes: [DictationOutcome]`, `enabledCalls: [Bool]`.

`MiniViewControllerTests` (with `FakeWindowWatcher` and `showsWindows: false`):

```swift
@MainActor func testTheTabShowsOnlyWhileOnAndAWindowIsInFront() {
    controller.setEnabled(true); watcher.send(window)
    XCTAssertTrue(controller.isShowingTab)
    watcher.send(nil)
    XCTAssertFalse(controller.isShowingTab)
    XCTAssertEqual(shownOrHiddenCalls, 2)
    watcher.send(window); controller.setEnabled(false)
    XCTAssertFalse(controller.isShowingTab)
}
@MainActor func testTheResultBelongsToTheWindowInFrontWhenItPasted() {
    controller.setEnabled(true); watcher.send(terminal)
    controller.finished(pastedOutcome)
    XCTAssertEqual(controller.result?.window, terminal.id)
    watcher.send(notes)
    XCTAssertEqual(controller.result?.window, terminal.id, "switching later does not move it")
}
@MainActor func testCopyFromThePanelCopiesTheNewestTranscript() { /* connect(latest:) returns t; copyLatest() → copied == [t] */ }
@MainActor func testDroppingTheTabLeftOfCentreSavesTheLeftSide() {
    watcher.send(FrontWindow(id: …, frame: CGRect(x: 100, y: 100, width: 800, height: 600), visibleFrame: screen))
    controller.dropped(atMidX: 300)
    XCTAssertTrue(preferences.miniViewOnLeft)
}
```

In the `IndicatorPanelTests` file, `testTheMiniViewPanelsNeverTakeFocus`: create `MiniTabPanel()` and `MiniInfoPanel()`. Assert `canBecomeKey` and `canBecomeMain` are false, `styleMask.contains(.nonactivatingPanel)`, `hidesOnDeactivate` is false, and `hasShadow` is false.

`AppModelTests` (with `FakeMiniView`):

```swift
@MainActor func testThePillStaysHiddenWhileTheTabShows() async throws {
    miniView.isShowingTab = true
    // a dictation from press to paste, as testTheIndicatorShowsWhileADictationRunsThenHides does
    XCTAssertFalse(indicator.everShown)
    XCTAssertTrue(miniView.works.contains { if case .recording = $0 { true } else { false } })
    XCTAssertEqual(miniView.outcomes.count, 1)
}
@MainActor func testThePillShowsWhenTheTabIsHidden() async throws { /* isShowingTab false → the indicator shows as today */ }
@MainActor func testThePillComesBackWhenTheTabHidesMidDictation() async throws {
    // recording with the tab showing; then isShowingTab = false and onTabShownOrHidden?() → the indicator shows
}
@MainActor func testTheMiniViewSettingIsSavedAndRestored() {
    model.miniViewEnabled = true
    XCTAssertTrue(preferences.miniViewEnabled); XCTAssertEqual(miniView.enabledCalls, [true])
    let secondMini = FakeMiniView()
    let again = makeModel(…, miniView: secondMini)   // same preferences
    again.start()
    XCTAssertEqual(secondMini.enabledCalls.last, true)
}
```

Give `FakeIndicator` an `everShown` flag.

- [ ] **Step 2: Run them and see them fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "MiniViewControllerTests|AppModelTests|IndicatorPanelTests"`
Expected: build errors for the new types and members.

- [ ] **Step 3: Implement the windows and views**

- **Both panels:** borderless with `.nonactivatingPanel`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`. `hidesOnDeactivate` and `canHide` are false; no shadow, clear background. `canBecomeKey` and `canBecomeMain` return false. They take mouse events through a hosting view that overrides `acceptsFirstMouse` to true.
- **`MiniTabView`:** 40 pt wide, padded 12 top and bottom, items 8 apart, `bg` with a hairline border.
  - **The marks:** draw them in a `Canvas` 26 × 18.
    - `restLine`: a 1 pt `text`-colour line at y 9.
    - `liveSpectrum`: `LevelLine(.tab)` points with a 1.5 pt stroke, using a horizontal linear gradient of `Theme.Color.spectrumStops` from x 0 to 26, so the colours are fixed in place. With Reduce Motion on, draw it flat.
    - `flatSpectrum`: the same gradient on a flat line, 1.5 pt.
    - `split`: a white line from (0, 9) to (12, 9), then rays to x 26 at y 3, 5.4, 7.8, 10.2, 12.6 and 15, coloured stops 1–6.
  - **The clipboard:** 12 × 15, using the spec's paths.
  - **The time:** `Theme.Font.mono(10)`.
  - **The word:** `Theme.Font.ui(9, medium: true)`, tracking 0.8, turned 90° so it reads top to bottom.
  - **Height:** measure every face and take the tallest, as `IndicatorPanel.indicatorSize()` does.
- **`MiniPanelView`:** 248 wide, `bg-elevated`, hairline border.
  - The header is DM Mono 12, muted: `TranscriptGroups.title(of: Place(t))` joined as "Terminal · Voice Dictation", with the time on the right (`LibraryModel.whenString`).
  - The text is `Theme.Font.ui(14)`, up to 8 lines.
  - The buttons, "Copy" and "Open", are secondary buttons with 4/10 padding. After Copy, its label reads "Copied" with the clipboard mark for 2 s.
  - With no transcript, it shows "Nothing dictated yet." and Open.
- **`MiniViewController`:**
  - It holds the tracker, the side from preferences, `result`, a `LevelLine(.tab)` reset on each new recording, and the panels.
  - It places the tab with `MiniViewLayout` on each tracker change, and hides both panels when `current` is nil.
  - A click without a drag toggles the panel. A drag moves the tab sideways and ends in `dropped(atMidX:)`.
  - The panel closes on a click outside (a global `.leftMouseDown` monitor, installed only while it's open), on a window change, when recording starts, and after Open.
  - It schedules one wake-up at `MiniTab.nextChange`.
  - `finished(_:)` records `MiniTabResult(status:dictated:arrived:window: tracker.current?.id)`.
- **`AppModel`:**
  - The convenience init passes `MiniViewController(tracker: FrontWindowTracker(), preferences: preferences)`.
  - `init` calls `connect(latest: { store.latest }, copy: { library.copy($0) }, openMainWindow: { NSApp.activate(); self.requestMainWindow() })` and sets `onTabShownOrHidden` to run `updateIndicator()`.
  - `start()` calls `setEnabled(preferences.miniViewEnabled)`.
  - `observeWorkForIndicator` also calls `workChanged(pipeline.work)`, and `onLevel` also calls `heard`. `finished(_:)` calls it after `store.add`.
  - `updateIndicator` hides the pill while `miniView?.isShowingTab == true`.
- **`MenuBarContent`:** a `Toggle("Mini View", …)` bound to `model.miniViewEnabled`, right after "Open VoiceDictation".

- [ ] **Step 4: Run them and see them pass; then the whole suite and a build**

Run: the Step 2 command, then the full suite, then the app build exactly as `scripts/run-dev.sh` lines 19–23 do it, without its `open` (copy `Package.resolved` aside, `xcodegen`, then `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme VoiceDictation -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build 2>&1 | tail -3`, then put `Package.resolved` back).
Expected: PASS; all tests pass; `** BUILD SUCCEEDED **`; `git status` shows no `Package.resolved` change. Don't open the built app: the installed copy is running, and the single-instance guard would turn it away anyway.

- [ ] **Step 5: Lint the design manifest**

Run: `npx --yes @google/design.md lint DESIGN.md`
Expected: no errors (as in Task 5).

- [ ] **Step 6: Commit**

```bash
git add Sources Tests DESIGN.md CLAUDE.md
git commit -m "feat: mini view tab that follows the front window"
```

---

## For Danny, once it's built (hands-on)

These need his eyes and his apps. The executor lists them in its final message, and doesn't do them.
- Turn on Mini View from the menu. The tab sits on the right of the window in front, and follows Terminal, Notes and a browser as he switches.
- Drag a window: the tab catches up, at the latest when the drag ends (spec, Call 14). If the jump at the end bothers him, hiding the tab during the drag is the follow-up.
- Drag the tab to the left. Every window then gets it on the left, and still does after a relaunch.
- Full screen hides it, and the bottom pill returns while it's hidden.
- Dictate into Terminal: the line is in colour while he speaks, flat in colour while it transcribes, then splits for Pasted, and goes white again after a few seconds. Switch windows and the time shows only on Terminal.
- Click the tab: the panel shows the dictation, Copy copies it, and Open brings up the window.
- A new Claude Code dictation lands under its folder's name. Deleting a group asks first and keeps pinned transcripts.
