import Foundation
import Observation
import SwiftData
import VoiceDictationLib

/// The main window's transcripts: the section, search, length and place
/// showing, the rows they list (newest first, by day and then place), the
/// headings folded, the one selected, and the sidebar's counts.
/// `AppModel` tells it about each transcript it keeps (`noteNewTranscript`),
/// so the list is current whether or not the window is open. It also does
/// what the detail's actions ask (Task 19): editing with autosave, Copy,
/// Paste again, Pin, Delete, Play audio, Re-transcribe with… and "Use this
/// one". The static helpers say what a row and the detail show. Use from the
/// main thread.
@MainActor @Observable
public final class LibraryModel {
    /// The sidebar's sections. The first four list transcripts, Places the
    /// project or app chosen from the Projects & apps panel (`show(_:)`);
    /// Models, Vocabulary and Settings show their own views (Tasks 20, 22
    /// and 24).
    public enum Section: String, CaseIterable, Identifiable, Sendable {
        case all, today, pinned, places, models, vocabulary, settings

        public var id: Self { self }

        /// The sidebar's words for it.
        var title: String {
            switch self {
            case .all: "All transcripts"
            case .today: "Today"
            case .pinned: "Pinned"
            case .places: "Projects & apps"
            case .models: "Models"
            case .vocabulary: "Vocabulary"
            case .settings: "Settings"
            }
        }

        /// The transcripts it lists; nil for a setup section, and for
        /// Places, whose transcripts are the place chosen (`LibraryModel.scope`).
        var scope: TranscriptStore.Scope? {
            switch self {
            case .all: .all
            case .today: .today
            case .pinned: .pinned
            case .places, .models, .vocabulary, .settings: nil
            }
        }

        /// The sidebar's two groups, in order.
        static let transcripts: [Section] = [.all, .today, .pinned]
        static let setup: [Section] = [.models, .vocabulary, .settings]
    }

    /// The section showing. Choosing one that lists transcripts lists them;
    /// choosing any but Places leaves the place chosen.
    public var section: Section = .all {
        didSet {
            guard section != oldValue else { return }
            if section != .places { place = nil }
            listRows()
        }
    }
    /// The search: the rows whose text contains it, ignoring case and accents.
    public var query = "" {
        didSet { if query != oldValue { listRows() } }
    }
    /// How long a row's recording is; one of unknown length shows only
    /// under Any. Applies with the search, the section and the place.
    public var length: LengthFilter = .any {
        didSet { if length != oldValue { listRows() } }
    }
    /// The project or app Places shows (`show(_:)`); nil in any other section.
    public private(set) var place: PlaceFilter?
    /// Whether the Projects & apps panel is open. Opening it lists the
    /// places as they are now (`placeEntries`).
    public var isPlacesPanelOpen = false {
        didSet { if isPlacesPanelOpen, !oldValue { placeEntries = Self.placeEntries(store.places()) } }
    }
    /// The panel's lines, as it last opened.
    private(set) var placeEntries: [PlaceEntry] = []
    /// The headings, day and group, Danny folded. They last while the app
    /// runs and are not saved.
    private var folded: Set<String> = []
    /// The day or group heading whose deletion waits for Danny's yes.
    public private(set) var headingDeletionToConfirm: HeadingDeletion?
    /// The transcript the detail shows. Choosing another saves the edit being
    /// typed, stops the recording playing, and shows its main text.
    public var selection: Transcript.ID? {
        didSet {
            guard selection != oldValue else { return }
            textSelection = nil
            versionShown = nil
            commitEdit()
            player.stop()
            if let message, message.transcript == oldValue { self.message = nil }
        }
    }
    /// The section's transcripts that match the search and the length,
    /// newest first. The setup sections leave them as the last transcript
    /// section listed them.
    public private(set) var rows: [Transcript] = []
    /// `rows` by day, then by place: what the list shows, set with `rows`.
    private(set) var days: [DayGroup] = []
    /// How many transcripts each transcript section holds, search aside.
    private var counts: [Section: Int] = [:]
    /// The pinned transcript whose deletion waits for Danny's yes.
    public private(set) var deletionToConfirm: Transcript.ID?
    /// Where Danny turned the selected transcript's Raw / Cleaned switch;
    /// nil shows its main text's side (`versionShowing`).
    private var versionShown: TextVersion?
    /// Danny's text for a transcript as he types it, until it is saved.
    private var draft: Draft?
    /// The models re-transcribing each transcript now.
    private(set) var running: [Transcript.ID: Set<ModelID>] = [:]
    /// The words the latest action left for Danny, and the transcript they
    /// are about.
    private var message: (transcript: Transcript.ID, text: String)?
    /// Plays one transcript's recording at a time.
    let player = AudioPlayer()

    /// The part of the detail's text that is selected, as its text view last
    /// reported it (Ruling T18-3). Only ⌘C reads it, so no view watches it.
    @ObservationIgnored var textSelection: NSRange?
    /// How long Paste again waits for the previous app to come back to the
    /// front before it copies instead (Ruling T19-3). Tests shorten it.
    @ObservationIgnored var pasteAgainWaitLimit: TimeInterval = 1
    @ObservationIgnored private let store: TranscriptStore
    /// Whether the window is open. While it is not, nobody sees the rows.
    @ObservationIgnored private(set) var isWindowOpen = false
    /// True for the whole Paste again run whenever there is a target app (Ruling T19-5), including after
    /// Danny brings the app back mid-run. It does NOT mean the app is hidden: `AppLifecycle` also checks
    /// `isHidden` before treating a window close as the run's hide, so keep both checks.
    @ObservationIgnored private(set) var isPastingAgain = false
    /// The re-transcription lane, which yields to dictations.
    @ObservationIgnored private let service: TranscriptionService
    /// The paster dictation uses: Paste again's tagged Cmd+V, and Copy.
    @ObservationIgnored private let paster: Pasting
    /// The words the engines should favour, as dictation passes them.
    @ObservationIgnored private let vocabulary: () -> [String]
    /// Danny's rules, which a re-transcription's text gets as a dictation's does.
    @ObservationIgnored private let replacements: () -> [Replacement]
    /// The key that dictates, which the empty list names.
    @ObservationIgnored private let hotkey: () -> HotkeyChoice
    /// Which apps are in front, and hiding this one, for Paste again.
    @ObservationIgnored private let system: PasteAgainSystem
    /// How long after the last keystroke an edit saves itself.
    @ObservationIgnored private let editSaveDelay: Duration
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// An edit being typed, not yet saved.
    private struct Draft {
        let transcript: Transcript
        var text: String
    }

    /// `editSaveDelay` is the autosave's wait, about half a second; tests
    /// pass their own.
    init(store: TranscriptStore, service: TranscriptionService, paster: Pasting,
         vocabulary: @escaping () -> [String] = { [] }, replacements: @escaping () -> [Replacement] = { [] },
         hotkey: @escaping () -> HotkeyChoice = { .globe },
         system: PasteAgainSystem,
         editSaveDelay: Duration = .milliseconds(500)) {
        self.store = store
        self.service = service
        self.paster = paster
        self.vocabulary = vocabulary
        self.replacements = replacements
        self.hotkey = hotkey
        self.system = system
        self.editSaveDelay = editSaveDelay
    }

    // MARK: - Listing

    /// The window has opened: lists everything again and selects the newest
    /// transcript. A selection kept from before, or taken by a dictation
    /// made while the window was closed, is one nobody was reading, and it
    /// may lie below the top of a list that opens at the top. Only real
    /// openings reach it: `AppLifecycle` filters out the return of a window
    /// Paste again hid (Ruling T19-5).
    public func windowOpened() {
        isWindowOpen = true
        // The app may have run for days without a dictation, which is when
        // recordings past a week go otherwise.
        store.pruneRecordings()
        reload()
        if scope != nil { selection = visibleRows.first?.id }
    }

    /// The window has closed: dictations are no longer listed or counted
    /// until it opens again, which does both. The edit being typed is saved,
    /// and the recording playing stops. Only real closes reach it:
    /// `AppLifecycle` filters out the hide Paste again does (Ruling T19-5).
    public func windowClosed() {
        isWindowOpen = false
        commitEdit()
        player.stop()
    }

    /// Lists the rows and counts again, as when the window opens.
    public func reload() {
        listRows()
        countTranscripts()
    }

    /// A transcript was just kept. With the window closed that costs
    /// nothing: opening lists and counts everything. With it open, the
    /// transcript joins the rows, at the top when it belongs to the section
    /// and the search, and the counts, which the store counts without
    /// loading. It never takes the selection from another transcript: only
    /// with none selected is it selected, if it is listed and not folded away.
    public func noteNewTranscript(_ t: Transcript) {
        stopPlayingIfRemoved()
        guard isWindowOpen else { return }
        listRows(keepingSelection: true)
        countTranscripts()
        if selection == nil, visibleRows.contains(where: { $0.id == t.id }) {
            selection = t.id
        }
    }

    /// Lists the transcripts of `scope` that match the search and the
    /// length, and groups them into `days`. Unless asked to keep it, a
    /// selection that is no longer listed, or is folded away, moves to the
    /// first visible row.
    private func listRows(keepingSelection: Bool = false) {
        guard let scope else { return }
        rows = store.search(query, scope: scope, length: length)
        days = TranscriptGroups.days(rows)
        guard !keepingSelection else { return }
        let visible = visibleRows
        if let selection, visible.contains(where: { $0.id == selection }) { return }
        selection = visible.first?.id
    }

    /// Lists the rows and counts again after an action that may take `ids`
    /// out of the list: a deletion, or unpinning on Pinned. If the selected
    /// one went, the row that takes its place is: the next visible one down
    /// that is still listed, or else the one above.
    private func relist(afterRemoving ids: Set<Transcript.ID>) {
        let before = visibleRows.map(\.id)
        listRows(keepingSelection: true)
        countTranscripts()
        guard let selection, ids.contains(selection), !rows.contains(where: { $0.id == selection }) else { return }
        self.selection = Self.neighbour(of: selection, before: before, after: visibleRows.map(\.id))
    }

    private func countTranscripts() {
        var counts: [Section: Int] = [:]
        for section in Section.transcripts {
            if let scope = section.scope { counts[section] = store.count(scope: scope) }
        }
        self.counts = counts
    }

    /// The number beside a section in the sidebar: its transcripts, search
    /// aside; for Models, the models ready to use, once they are listed.
    /// Places, Vocabulary and Settings have none.
    func count(of section: Section, models: [ModelDescriptor]) -> Int? {
        switch section {
        case .all, .today, .pinned: counts[section]
        case .models: models.isEmpty ? nil : models.filter { $0.state == .ready }.count
        case .places, .vocabulary, .settings: nil
        }
    }

    /// The transcript the detail shows, if it is listed.
    var selectedTranscript: Transcript? {
        guard let selection else { return nil }
        return rows.first { $0.id == selection }
    }

    /// Moves the selection `step` visible rows down, or up when negative,
    /// stopping at either end; rows folded away are skipped. With nothing
    /// selected, down selects the first visible row and up the last.
    func moveSelection(by step: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        guard let selection, let index = rows.firstIndex(where: { $0.id == selection }) else {
            self.selection = (step < 0 ? rows.last : rows.first)?.id
            return
        }
        self.selection = rows[min(max(index + step, 0), rows.count - 1)].id
    }

    // MARK: - Organising: places, folds and deleting a heading

    /// A line of the Projects & apps panel, with its count: an app, or one
    /// of its folders nested under it, or its "No folder recorded".
    struct PlaceEntry: Identifiable, Equatable {
        let filter: PlaceFilter
        let title: String
        let count: Int
        let isNested: Bool
        var id: PlaceFilter { filter }
    }

    /// A day or group heading's Delete, waiting for Danny's yes: the
    /// unpinned transcripts listed under it, and the words that ask.
    public struct HeadingDeletion: Identifiable, Equatable {
        /// The heading's: a `DayGroup.id` or a `PlaceGroup.id`.
        public let id: String
        let ids: [Transcript.ID]
        let title: String
        let message: String
    }

    /// The transcripts the list shows: the section's, or in Places, the
    /// place chosen's; nil for a setup section.
    var scope: TranscriptStore.Scope? {
        guard section == .places else { return section.scope }
        return place.map { .place($0) }
    }

    /// Whether each day's rows sit under group headings: not while one
    /// folder, or one app's transcripts without a folder, shows alone, as
    /// every row is from that place.
    var showsGroupHeadings: Bool {
        guard section == .places, case .place? = place else { return true }
        return false
    }

    /// The place showing, for the sidebar under "Projects & apps": its
    /// folder, or else its app; nil when Places is not showing.
    var placeTitle: String? {
        guard section == .places, let place else { return nil }
        switch place {
        case .app(let app): return TranscriptGroups.title(of: Place(app: app, project: nil)).name
        case .place(let place): return TranscriptGroups.title(of: place).name
        }
    }

    /// Shows `filter`'s transcripts across every day, in Places, and closes
    /// the Projects & apps panel.
    public func show(_ filter: PlaceFilter) {
        isPlacesPanelOpen = false
        place = filter
        if section == .places { listRows() } else { section = .places }
    }

    /// Folds a day or group heading, or opens it again. A selected row it
    /// folds away hands the selection to the nearest visible row, as a
    /// deletion does; with none left, nothing is selected.
    func toggleFold(_ headingID: String) {
        let before = visibleRows.map(\.id)
        if folded.remove(headingID) == nil { folded.insert(headingID) }
        let after = visibleRows.map(\.id)
        guard let selection, !after.contains(selection) else { return }
        self.selection = Self.neighbour(of: selection, before: before, after: after)
    }

    func isFolded(_ headingID: String) -> Bool {
        folded.contains(headingID)
    }

    /// The rows the list shows, in its order: by day, then by group, those
    /// not under a folded day nor, while group headings show, a folded group.
    var visibleRows: [Transcript] {
        days.flatMap { day -> [Transcript] in
            guard !folded.contains(day.id) else { return [] }
            guard showsGroupHeadings else { return day.transcripts }
            return day.groups.flatMap { folded.contains($0.id) ? [] : $0.transcripts }
        }
    }

    /// What a heading's Delete takes of `transcripts`: the unpinned, since
    /// pinning means "keep this". A heading with none offers no Delete.
    func deletable(_ transcripts: [Transcript]) -> [Transcript] {
        transcripts.filter { !$0.pinned }
    }

    /// Asks before deleting the unpinned transcripts listed under the day,
    /// those folded away included. With a place chosen, the day holds only
    /// that place's, so the words say only those shown go.
    func askToDelete(day: DayGroup) {
        ask(toDelete: day.transcripts, heading: day.id, group: nil, on: day, filtered: isNarrowed || place != nil)
    }

    /// Asks before deleting the unpinned transcripts listed under the group.
    func askToDelete(group: PlaceGroup, on day: DayGroup) {
        ask(toDelete: group.transcripts, heading: group.id, group: TranscriptGroups.title(of: group.place).name,
            on: day, filtered: isNarrowed)
    }

    private func ask(toDelete transcripts: [Transcript], heading: String, group: String?, on day: DayGroup,
                     filtered: Bool) {
        let doomed = deletable(transcripts)
        guard !doomed.isEmpty else { return }
        let words = Self.headingDeletionWords(count: doomed.count, group: group,
                                              dayTitle: TranscriptGroups.dayTitle(day.day, now: Date()),
                                              filtered: filtered)
        headingDeletionToConfirm = HeadingDeletion(id: heading, ids: doomed.map(\.id), title: words.title,
                                                   message: words.message)
    }

    /// Whether a search or a length narrows what the headings hold.
    private var isNarrowed: Bool {
        !query.isEmpty || length != .any
    }

    /// Danny said yes: the heading's transcripts go, in one save, and then
    /// their recordings. First each one's edit, playback and message end,
    /// as for a single deletion. A selected one hands the selection to the
    /// nearest row left. Pinned transcripts never go.
    public func confirmHeadingDeletion() {
        guard let deletion = headingDeletionToConfirm else { return }
        headingDeletionToConfirm = nil
        let ids = Set(deletion.ids)
        let doomed = deletable(rows.filter { ids.contains($0.id) })
        guard !doomed.isEmpty else { return }
        for t in doomed { letGo(of: t) }
        store.delete(doomed)
        relist(afterRemoving: ids)
    }

    /// Danny kept them.
    public func cancelHeadingDeletion() {
        headingDeletionToConfirm = nil
    }

    /// The Projects & apps panel's lines, from the store's `places()`: apps
    /// by their total, most first, ties by name, and "Unknown app" last.
    /// An app's folders sit nested under it, by count and then name, with
    /// "No folder recorded" after them for its transcripts without one. An
    /// app with no folders is one line.
    nonisolated static func placeEntries(_ counts: [PlaceCount]) -> [PlaceEntry] {
        let byApp = Dictionary(grouping: counts, by: \.place.app)
        let totals = byApp.mapValues { $0.reduce(0) { $0 + $1.count } }
        let apps = byApp.keys.sorted { a, b in
            guard let a else { return false }
            guard let b else { return true }
            let (totalA, totalB) = (totals[a] ?? 0, totals[b] ?? 0)
            return totalA != totalB ? totalA > totalB : nameOrder(a, b)
        }
        var entries: [PlaceEntry] = []
        for app in apps {
            let places = byApp[app] ?? []
            entries.append(PlaceEntry(filter: .app(app), title: TranscriptGroups.title(of: Place(app: app, project: nil)).name,
                                      count: totals[app] ?? 0, isNested: false))
            let folders = places.filter { $0.place.project != nil }.sorted {
                $0.count != $1.count ? $0.count > $1.count : nameOrder($0.place.project ?? "", $1.place.project ?? "")
            }
            guard !folders.isEmpty else { continue }
            for folder in folders {
                entries.append(PlaceEntry(filter: .place(folder.place), title: folder.place.project ?? "",
                                          count: folder.count, isNested: true))
            }
            if let none = places.first(where: { $0.place.project == nil }) {
                entries.append(PlaceEntry(filter: .place(none.place), title: "No folder recorded", count: none.count,
                                          isNested: true))
            }
        }
        return entries
    }

    /// Names in Finder's order; any it holds the same, by their characters.
    private nonisolated static func nameOrder(_ a: String, _ b: String) -> Bool {
        let order = a.localizedStandardCompare(b)
        return order == .orderedSame ? a < b : order == .orderedAscending
    }

    /// The words that ask before a heading's Delete. A day heading
    /// (`group` nil): "Everything dictated today, …"; a group heading:
    /// "Everything from Voice Dictation today, …". With a search or length
    /// on (`filtered`): "The 4 shown today, …" and "The 4 shown under
    /// Voice Dictation today, …". "Today" and "Yesterday" read in lower
    /// case; any other day title follows "on".
    nonisolated static func headingDeletionWords(count: Int, group: String?, dayTitle: String,
                                                 filtered: Bool) -> (title: String, message: String) {
        let title = count == 1 ? "Delete 1 transcript?" : "Delete \(count) transcripts?"
        let day = switch dayTitle {
        case "Today": "today"
        case "Yesterday": "yesterday"
        default: "on \(dayTitle)"
        }
        let which = switch (group, filtered) {
        case (let group?, false): "Everything from \(group) \(day)"
        case (nil, false): "Everything dictated \(day)"
        case (let group?, true): "The \(count) shown under \(group) \(day)"
        case (nil, true): "The \(count) shown \(day)"
        }
        return (title, "\(which), with any recordings kept for them. Pinned transcripts stay.")
    }

    /// A row's muted line under a day heading: the time of day, "12:52 AM",
    /// even on older days, since the heading gives the day; and the length,
    /// "7s", nil when it is unknown, as for imported history.
    nonisolated static func rowTimes(_ t: Transcript, calendar: Calendar = .current,
                                     locale: Locale = .current) -> (time: String, length: String?) {
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                     calendar: calendar, timeZone: calendar.timeZone)
        return (plainSpaces(t.date.formatted(style)), t.recordingSeconds > 0 ? lengthString(t.recordingSeconds) : nil)
    }

    // MARK: - Editing

    /// Danny's text for `t`, as he types it. It saves itself through
    /// `store.updateText`, which marks it Edited, `editSaveDelay` after the
    /// last change, and at once when the edit ends (`commitEdit`).
    public func edit(_ t: Transcript, text: String) {
        if let draft, draft.transcript.id != t.id { commitEdit() }
        draft = Draft(transcript: t, text: text)
        saveTask?.cancel()
        let delay = editSaveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveDraft()
        }
    }

    /// The text the detail shows for `t`: the other version when the Raw /
    /// Cleaned switch is turned to it, otherwise the edit being typed, or
    /// else its main text.
    func shownText(_ t: Transcript) -> String {
        if !showsMainText(t) {
            return versionShowing(t) == .raw ? t.rawText : t.cleanedText ?? t.text
        }
        if let draft, draft.transcript.id == t.id { return draft.text }
        return t.text
    }

    /// Ends the edit being typed, as the selection changes, the window
    /// closes, the text stops being edited, or another action needs the
    /// text: saves it, or drops an empty one, which cannot be saved, so the
    /// previous text shows again.
    public func commitEdit() {
        saveTask?.cancel()
        saveTask = nil
        guard let draft else { return }
        self.draft = nil
        if !Self.isBlank(draft.text) { store.updateText(draft.transcript, draft.text) }
    }

    /// Ends the edit being typed in `t`, before an action on `t` reads or
    /// replaces its text. An edit of another transcript goes on: a
    /// re-transcription can finish while Danny types elsewhere.
    private func commitEdit(of t: Transcript) {
        if draft?.transcript.id == t.id { commitEdit() }
    }

    /// The autosave: as `commitEdit`, except that an empty text stays on
    /// show, since Danny may be about to type over it.
    private func saveDraft() {
        guard let draft, !Self.isBlank(draft.text) else { return }
        self.draft = nil
        store.updateText(draft.transcript, draft.text)
    }

    // MARK: - Actions

    /// Copy: the transcript's text on the clipboard.
    public func copy(_ t: Transcript) {
        commitEdit(of: t)
        guard !t.text.isEmpty else { return }
        paster.copy(text: t.text)
    }

    /// Paste again, into the app that was in front before this one and only
    /// there (Ruling T19-3). The window hides, so that app comes back to the
    /// front, and the text pastes once it is there. If it is not back within
    /// `pasteAgainWaitLimit`, the text goes on the clipboard instead and the
    /// window comes back to say so. With no such app, the window stays and
    /// the text is copied. Without Accessibility nothing can paste, and the
    /// text is left on the clipboard.
    public func pasteAgain(_ t: Transcript) async {
        commitEdit(of: t)
        let text = t.text
        let id = t.id
        guard !text.isEmpty else { return }
        clearMessage(for: id)
        let target = system.previousApp()
        isPastingAgain = target != nil
        defer { isPastingAgain = false }
        if target != nil { system.hide() }
        let start = ContinuousClock.now
        while true {
            let waited = Self.seconds(start.duration(to: .now))
            var step = Self.pasteAgainStep(target: target, frontmost: system.frontmostApp(), waited: waited,
                                           limit: pasteAgainWaitLimit)
            if step == .wait, (try? await Task.sleep(for: .milliseconds(20))) == nil { step = .copyInstead }
            switch step {
            case .wait:
                continue
            case .paste:
                if !paster.paste(text: text) { show(Self.copiedMessage, for: id) }
            case .copyInstead:
                paster.copy(text: text)
                show(Self.copiedMessage, for: id)
                if target != nil { system.unhide() }
            }
            return
        }
    }

    /// Pin or unpin. Unpinned on Pinned, it leaves the list.
    public func togglePin(_ t: Transcript) {
        store.setPinned(t, !t.pinned)
        relist(afterRemoving: [t.id])
    }

    /// Delete. An unpinned transcript goes at once; a pinned one waits for
    /// Danny's yes (`deletionToConfirm`) and goes when asked again with
    /// `confirmed`. Its edit and its playback go with it.
    public func delete(_ t: Transcript, confirmed: Bool = false) {
        guard confirmed || !t.pinned else {
            deletionToConfirm = t.id
            return
        }
        deletionToConfirm = nil
        letGo(of: t)
        let id = t.id
        store.delete(t)
        relist(afterRemoving: [id])
    }

    /// Before `t` is deleted: the edit being typed in it is dropped, never
    /// saved to a deleted transcript; its recording stops playing; and the
    /// words left about it go.
    private func letGo(of t: Transcript) {
        if draft?.transcript.id == t.id {
            saveTask?.cancel()
            draft = nil
        }
        if isPlaying(t) { player.stop() }
        clearMessage(for: t.id)
    }

    /// Danny kept the pinned transcript.
    public func cancelDeletion() {
        deletionToConfirm = nil
    }

    /// "Use this one": the alternate becomes the main text. The store deletes
    /// the alternate, so `t.alternates` must be read again afterwards (Task
    /// 11). A failed transcript that gets its text this way has it put on the
    /// clipboard and becomes Copied (Review Focus 1).
    public func promote(_ alternate: AlternateResult, in t: Transcript) {
        promote(alternate, in: t, clipboardWhenAsked: nil)
    }

    /// `promote`, for a click (`clipboardWhenAsked` nil) or for a failed
    /// transcript's re-transcription that has finished, with the clipboard's
    /// change count when it was asked for. A failed transcript becomes Copied
    /// either way; its text goes on the clipboard only as `copiesResult`
    /// says, so it never replaces what was copied since (Ruling T19-4).
    private func promote(_ alternate: AlternateResult, in t: Transcript, clipboardWhenAsked: Int?) {
        commitEdit(of: t)
        let wasFailed = t.status == .failed
        store.promote(alternate, in: t)
        showMainText(of: t)
        guard wasFailed, !t.text.isEmpty else { return }
        if Self.copiesResult(clipboardWhenAsked: clipboardWhenAsked, clipboardNow: paster.clipboardChangeCount) {
            paster.copy(text: t.text)
            show(Self.copiedMessage, for: t.id)
        } else {
            show(Self.useCopyMessage, for: t.id)
        }
        store.setStatus(t, .copied)
    }

    /// "Use cleaned": a cleanup that came back after the paste becomes the
    /// main text (`offersUseCleaned`).
    public func useCleaned(_ t: Transcript) {
        commitEdit(of: t)
        store.useCleaned(t)
        showMainText(of: t)
    }

    /// "Revert to raw": the dictation's own raw text becomes the main text
    /// again; the text it replaces is kept.
    public func revertToRaw(_ t: Transcript) {
        commitEdit(of: t)
        store.revertToRaw(t)
        showMainText(of: t)
    }

    // MARK: - Raw and cleaned (Task 21)

    /// The two sides of the detail's Raw / Cleaned switch.
    public enum TextVersion: Sendable {
        case raw, cleaned
    }

    /// Turns the Raw / Cleaned switch to `version` for `t`, the selected
    /// transcript: the detail shows that version, the main text included
    /// when it is on that side (`showsMainText`). Nothing about `t` changes.
    /// The edit being typed is saved first. Only a turn to the other side is
    /// remembered; the main text's side follows the main text, so an edit
    /// that moves it there stays on show.
    public func show(_ version: TextVersion, of t: Transcript) {
        commitEdit(of: t)
        guard t.id == selection, version != versionShowing(t) else { return }
        versionShown = version == Self.mainTextVersion(t) ? nil : version
        // It was a selection in the other text.
        textSelection = nil
    }

    /// After an action gives `t` another main text: the detail shows it.
    private func showMainText(of t: Transcript) {
        if t.id == selection { versionShown = nil }
    }

    /// The side the switch is on for `t`: where Danny turned it for the
    /// selected transcript, otherwise the main text's side.
    func versionShowing(_ t: Transcript) -> TextVersion {
        if t.id == selection, let versionShown { return versionShown }
        return Self.mainTextVersion(t)
    }

    /// Whether the detail shows `t`'s main text, which Danny can edit,
    /// rather than the other version, which he can only read and copy.
    func showsMainText(_ t: Transcript) -> Bool {
        !Self.offersRawCleanedSwitch(t) || versionShowing(t) == Self.mainTextVersion(t)
    }

    /// The Raw / Cleaned switch is offered when cleanup changed the text.
    nonisolated static func offersRawCleanedSwitch(_ t: Transcript) -> Bool {
        guard let cleaned = t.cleanedText, !isBlank(cleaned) else { return false }
        return cleaned != t.rawText
    }

    /// The side the main text is on: Raw while it is the raw text, as after
    /// "Revert to raw" or a cleanup that came late; otherwise Cleaned, which
    /// is the cleaned text or what Danny made of it.
    nonisolated static func mainTextVersion(_ t: Transcript) -> TextVersion {
        t.text == t.rawText ? .raw : .cleaned
    }

    // MARK: - Re-transcribing

    /// The models re-transcribing the selected transcript now.
    public var retranscribing: Set<ModelID> {
        guard let selection else { return [] }
        return running[selection] ?? []
    }

    /// Re-transcribes the transcript's kept recording with `model`, in the
    /// service's re-transcription lane, which yields to dictations. The
    /// result is kept as an alternate, one per model: another run replaces
    /// it. A failed transcript takes the result as its main text (`promote`),
    /// and onto the clipboard only if nothing was copied since the request
    /// (Ruling T19-4). Without a recording, or when the model fails or hears
    /// nothing, it says why. A transcript deleted meanwhile gets nothing.
    public func retranscribe(_ t: Transcript, with model: ModelID) async {
        let id = t.id
        guard let name = t.audioFileName, let archive = store.audio else {
            show(Self.audioGone, for: id)
            return
        }
        guard running[id]?.contains(model) != true else { return }
        let clipboardWhenAsked = paster.clipboardChangeCount
        clearMessage(for: id)
        running[id, default: []].insert(model)
        defer { stopRunning(model, for: id) }
        let result: TranscriptionResult
        do {
            // Reading a long recording takes a moment: off the main thread.
            let clip = try await Task.detached { try archive.load(name) }.value
            let transcribed = try await service.transcribe(clip, with: model, vocabulary: vocabulary())
            // Ruling T22-1: the rules apply here too, so "Use this one" keeps them.
            result = TranscriptionResult(text: Replacements.apply(replacements(), to: transcribed.text),
                                         model: transcribed.model, elapsed: transcribed.elapsed)
        } catch {
            show("Could not re-transcribe: \(DictationPipeline.describe(error))", for: id)
            return
        }
        // A deleted transcript has left its store (SwiftData clears its context).
        guard t.modelContext != nil else { return }
        guard !Self.isBlank(result.text) else {
            show("Nothing was heard in the recording.", for: id)
            return
        }
        store.addAlternate(to: t, result)
        guard t.status == .failed,
              let alternate = t.alternates.first(where: { !$0.wasMain && $0.modelKey == result.model.storageKey })
        else { return }
        promote(alternate, in: t, clipboardWhenAsked: clipboardWhenAsked)
    }

    private func stopRunning(_ model: ModelID, for id: Transcript.ID) {
        running[id]?.remove(model)
        if running[id]?.isEmpty == true { running[id] = nil }
    }

    // MARK: - Playing

    /// Plays the transcript's kept recording, or stops it if it is playing.
    public func togglePlay(_ t: Transcript) {
        if isPlaying(t) {
            player.stop()
            return
        }
        guard let url = recordingURL(t) else {
            show(Self.audioGone, for: t.id)
            return
        }
        do {
            try player.play(url)
        } catch {
            Log.info("[LIBRARY] Could not play \(url.lastPathComponent): \(error)")
            show("The recording could not be played.", for: t.id)
        }
    }

    /// Stops the recording playing if keeping the latest dictation removed
    /// its file: its transcript no longer names it, so its detail could not
    /// stop it (code review, 2026-11-20).
    private func stopPlayingIfRemoved() {
        guard let url = player.playing, !FileManager.default.fileExists(atPath: url.path) else { return }
        player.stop()
    }

    /// Whether the transcript's recording is the one playing.
    func isPlaying(_ t: Transcript) -> Bool {
        guard let url = recordingURL(t) else { return false }
        return player.playing == url
    }

    private func recordingURL(_ t: Transcript) -> URL? {
        guard let name = t.audioFileName, let archive = store.audio else { return nil }
        return archive.url(for: name)
    }

    // MARK: - Messages

    /// The words the latest action left about `t`, if any.
    func message(for t: Transcript) -> String? {
        guard let message, message.transcript == t.id else { return nil }
        return message.text
    }

    private func show(_ text: String, for id: Transcript.ID) {
        message = (id, text)
    }

    private func clearMessage(for id: Transcript.ID) {
        if message?.transcript == id { message = nil }
    }

    // MARK: - What the list says

    /// What the list shows instead of rows; nil when it has rows. A store
    /// that cannot be opened says so whatever the search (Review Focus 5).
    var emptyMessage: String? {
        if case .unavailable(let message) = store.health { return message }
        guard rows.isEmpty else { return nil }
        if !query.isEmpty { return "No transcripts match “\(query)”." }
        if length != .any { return "No transcripts of that length." }
        let anyKept = (counts[.all] ?? 0) > 0
        switch section {
        case .today where anyKept: return "Nothing dictated today."
        case .pinned where anyKept: return "No pinned transcripts."
        default: return "Nothing dictated yet. Hold \(hotkey().displayName) and speak."
        }
    }

    /// Ruling T18-1: once a damaged store was moved aside and a new one
    /// started, the words saying so, shown above the list, which works as usual.
    var notice: String? {
        guard case .recovered(let message) = store.health else { return nil }
        return message
    }

    /// What ⌘C copies: the selected part of the detail's text, or else the
    /// whole of it; nil when it has no text (Ruling T18-3). That is the
    /// selected transcript, or the version the Raw / Cleaned switch shows.
    var copyCommandText: String? {
        guard let t = selectedTranscript else { return nil }
        return Self.textToCopy(shownText(t), selectedRange: textSelection)
    }

    // MARK: - Words for a transcript

    /// A row's muted line: the app, and `time · length`, or just the time
    /// when the length is unknown, as for imported history.
    nonisolated static func rowMeta(_ t: Transcript, now: Date, calendar: Calendar = .current,
                                    locale: Locale = .current) -> (app: String, when: String) {
        let when = whenString(t.date, now: now, calendar: calendar, locale: locale)
        guard t.recordingSeconds > 0 else { return (appName(t), when) }
        return (appName(t), "\(when) · \(lengthString(t.recordingSeconds))")
    }

    /// The detail's title: the app and the time, always with the time of
    /// day: "Terminal · 7:42 PM", "Terminal · Yesterday, 6:15 PM",
    /// "Terminal · Nov 3, 4:03 PM", "Terminal · Jan 3, 2025, 4:03 PM".
    nonisolated static func title(_ t: Transcript, now: Date, calendar: Calendar = .current,
                                  locale: Locale = .current) -> String {
        let day = whenString(t.date, now: now, calendar: calendar, locale: locale)
        guard !calendar.isDate(t.date, inSameDayAs: now) else { return "\(appName(t)) · \(day)" }
        let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                    calendar: calendar, timeZone: calendar.timeZone)
        return "\(appName(t)) · \(day), \(plainSpaces(t.date.formatted(time)))"
    }

    /// The app it was dictated into. Imported history does not know it.
    nonisolated static func appName(_ t: Transcript) -> String {
        guard let name = t.appName, !name.isEmpty else { return "Unknown app" }
        return name
    }

    /// When it was dictated, as a row says it: the time today, then
    /// "Yesterday", then the day ("Nov 3"), with the year when it is not this
    /// year's. Days turn at midnight in `calendar`'s time zone. Tests pass
    /// their own calendar and locale (Ruling T18-2).
    nonisolated static func whenString(_ date: Date, now: Date, calendar: Calendar = .current,
                                       locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                        calendar: calendar, timeZone: calendar.timeZone)
            return plainSpaces(date.formatted(time))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let day = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated).day()
        let thisYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        return plainSpaces(date.formatted(thisYear ? day : day.year()))
    }

    /// en_US puts a narrow no-break space (U+202F) before AM and PM, a
    /// character DM Mono lacks; a plain space keeps the line in one font.
    private nonisolated static func plainSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// A recording's length on a row, to the nearest second: "14s", "1m 15s", "5m".
    nonisolated static func lengthString(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
        let minutes = total / 60
        let rest = total % 60
        if minutes == 0 { return "\(rest)s" }
        return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
    }

    /// The detail's four facts, and a fifth, "Cleaned in", for a transcript
    /// that was cleaned up (Task 21). `models` (as `AppModel.models` lists
    /// them) name the model; one not listed shows its storage key. A time the
    /// transcript does not know (imported history, a failed dictation's
    /// transcription) reads "—".
    nonisolated static func facts(_ t: Transcript, models: [ModelDescriptor] = []) -> [(label: String, value: String)] {
        var facts: [(label: String, value: String)] = [
            ("Length", tenths(t.recordingSeconds)),
            ("Transcribed in", tenths(t.transcribeSeconds)),
            ("Model", modelName(t.modelKey, in: models)),
            ("Words", String(t.text.split(whereSeparator: \.isWhitespace).count)),
        ]
        if let cleanup = t.cleanupSeconds { facts.append(("Cleaned in", tenths(cleanup))) }
        return facts
    }

    /// Seconds to a tenth, "14.2s"; "—" when not known.
    nonisolated static func tenths(_ seconds: Double) -> String {
        seconds > 0 && seconds.isFinite ? String(format: "%.1fs", seconds) : "—"
    }

    /// A model's display name from `models`, or its storage key when it is
    /// not listed. whisper-cli, retired in Task 27A, lists nothing, but old
    /// transcripts and the imported history name its models: those read
    /// "whisper-cli base.en".
    nonisolated static func modelName(_ storageKey: String, in models: [ModelDescriptor]) -> String {
        if let listed = models.first(where: { $0.id.storageKey == storageKey }) { return listed.displayName }
        if let id = ModelID(storageKey: storageKey), id.engine == .whisperCLI { return "whisper-cli \(id.name)" }
        return storageKey
    }

    /// The status in a word: status is words, never colour (Prism). A
    /// transcript Danny edited reads "Edited", whatever happened at the paste.
    nonisolated static func statusWord(_ t: Transcript) -> String {
        if t.isEdited { return "Edited" }
        return switch t.status {
        case .pasted: "Pasted"
        case .copied: "Copied"
        case .failed: "Failed"
        }
    }

    /// The text a row and the detail show: the transcript's own, or for a
    /// failed dictation, which has none, why it failed (`isReason`).
    nonisolated static func displayText(_ t: Transcript) -> (text: String, isReason: Bool) {
        guard t.text.isEmpty else { return (t.text, false) }
        return (t.failure ?? "Nothing was transcribed.", true)
    }

    /// What ⌘C copies (Ruling T18-3): the selected part of `text` when
    /// there is one, otherwise all of it; nil when there is no text. The
    /// range counts UTF-16 units, as a text view's does.
    nonisolated static func textToCopy(_ text: String, selectedRange: NSRange?) -> String? {
        if let selectedRange, selectedRange.length > 0, let range = Range(selectedRange, in: text) {
            return String(text[range])
        }
        return text.isEmpty ? nil : text
    }

    // MARK: - What the actions offer

    /// Why Play audio and Re-transcribe with… cannot be used.
    nonisolated static let audioGone = "Audio no longer kept"
    /// What Danny is told when a text went on the clipboard, not into an app.
    nonisolated static let copiedMessage = "Copied — paste with ⌘V"
    /// What Danny is told when a failed transcript's re-transcription became
    /// its text but stayed off the clipboard, which held a newer copy.
    nonisolated static let useCopyMessage = "Re-transcribed — use Copy"

    /// Whether a failed transcript's new text goes on the clipboard (Ruling
    /// T19-4). A click on "Use this one" (`clipboardWhenAsked` nil) copies at
    /// once. A re-transcription can finish long after it was asked for, when
    /// dictations hold it up, so it copies only if the clipboard's change
    /// count is still the one from then: whatever was put there since, by any
    /// app, stays, as `PasteEngine` never puts a clipboard back over a newer
    /// copy.
    nonisolated static func copiesResult(clipboardWhenAsked: Int?, clipboardNow: Int) -> Bool {
        guard let clipboardWhenAsked else { return true }
        return clipboardWhenAsked == clipboardNow
    }

    /// Why the transcript cannot be played or re-transcribed: its recording
    /// is no longer kept (pruned, or never kept). Nil when it can.
    nonisolated static func audioUnavailableReason(_ t: Transcript) -> String? {
        t.audioFileName == nil ? audioGone : nil
    }

    /// "Re-transcribe with…": the ready models other than the one behind the
    /// main text. A failed transcript (its model failed, or the dictation was
    /// skipped) is offered every ready model, its own included. None without
    /// a recording.
    nonisolated static func retranscribeChoices(_ t: Transcript, models: [ModelDescriptor]) -> [ModelDescriptor] {
        guard audioUnavailableReason(t) == nil else { return [] }
        return models.filter { $0.state == .ready && (t.status == .failed || $0.id.storageKey != t.modelKey) }
    }

    /// "Use cleaned" is offered for a cleanup that came back after the paste:
    /// the main text is still the raw text, and the cleaned text differs.
    nonisolated static func offersUseCleaned(_ t: Transcript) -> Bool {
        guard let cleaned = t.cleanedText, !isBlank(cleaned) else { return false }
        return t.text == t.rawText && cleaned != t.rawText
    }

    /// "Revert to raw" brings back the dictation's own raw text: offered for
    /// an edited transcript, and for one cleanup changed (Task 21), while the
    /// main text is not the raw text already.
    nonisolated static func offersRevertToRaw(_ t: Transcript) -> Bool {
        guard !isBlank(t.rawText), t.text != t.rawText else { return false }
        return t.isEdited || offersRawCleanedSwitch(t)
    }

    /// The row that takes the place of `id` when it leaves the list: the next
    /// one down that is still listed, or else the nearest above.
    nonisolated static func neighbour(of id: UUID, before: [UUID], after: [UUID]) -> UUID? {
        let listed = Set(after)
        guard let index = before.firstIndex(of: id) else { return after.first }
        return before[(index + 1)...].first(where: listed.contains) ?? before[..<index].last(where: listed.contains)
    }

    private nonisolated static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private nonisolated static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
