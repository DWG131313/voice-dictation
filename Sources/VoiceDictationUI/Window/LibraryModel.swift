import Foundation
import Observation
import VoiceDictationLib

/// The main window's transcripts: the section and search showing, the rows
/// they list (newest first), the one selected, and the sidebar's counts.
/// `AppModel` tells it about each transcript it keeps (`noteNewTranscript`),
/// so the list is current whether or not the window is open. The static
/// helpers say what a row and the detail show. Use from the main thread.
@MainActor @Observable
public final class LibraryModel {
    /// The sidebar's sections. The first three list transcripts. Models,
    /// Vocabulary and Settings are placeholders until Tasks 20, 22 and 24.
    public enum Section: String, CaseIterable, Identifiable, Sendable {
        case all, today, pinned, models, vocabulary, settings

        public var id: Self { self }

        /// The sidebar's words for it.
        var title: String {
            switch self {
            case .all: "All transcripts"
            case .today: "Today"
            case .pinned: "Pinned"
            case .models: "Models"
            case .vocabulary: "Vocabulary"
            case .settings: "Settings"
            }
        }

        /// The transcripts it lists; nil for a setup section.
        var scope: TranscriptStore.Scope? {
            switch self {
            case .all: .all
            case .today: .today
            case .pinned: .pinned
            case .models, .vocabulary, .settings: nil
            }
        }

        /// The sidebar's two groups, in order.
        static let transcripts: [Section] = [.all, .today, .pinned]
        static let setup: [Section] = [.models, .vocabulary, .settings]
    }

    /// The section showing. Choosing one that lists transcripts lists them.
    public var section: Section = .all {
        didSet { if section != oldValue { listRows() } }
    }
    /// The search: the rows whose text contains it, ignoring case and accents.
    public var query = "" {
        didSet { if query != oldValue { listRows() } }
    }
    /// The transcript the detail shows.
    public var selection: Transcript.ID? {
        didSet { if selection != oldValue { textSelection = nil } }
    }
    /// The section's transcripts that match the search, newest first. The
    /// setup sections leave them as the last transcript section listed them.
    public private(set) var rows: [Transcript] = []
    /// How many transcripts each transcript section holds, search aside.
    private var counts: [Section: Int] = [:]

    /// The part of the detail's text that is selected, as its text view last
    /// reported it (Ruling T18-3). Only ⌘C reads it, so no view watches it.
    @ObservationIgnored var textSelection: NSRange?
    @ObservationIgnored private let store: TranscriptStore
    /// Whether the window is open. While it is not, nobody sees the rows.
    @ObservationIgnored private var isWindowOpen = false

    public init(store: TranscriptStore) {
        self.store = store
    }

    // MARK: - Listing

    /// The window has opened: lists everything again and selects the newest
    /// transcript. A selection kept from before, or taken by a dictation
    /// made while the window was closed, is one nobody was reading, and it
    /// may lie below the top of a list that opens at the top.
    public func windowOpened() {
        isWindowOpen = true
        reload()
        if section.scope != nil { selection = rows.first?.id }
    }

    /// The window has closed: dictations are no longer listed or counted
    /// until it opens again, which does both.
    public func windowClosed() {
        isWindowOpen = false
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
    /// with none selected is it selected, if it is listed.
    public func noteNewTranscript(_ t: Transcript) {
        guard isWindowOpen else { return }
        listRows(keepingSelection: true)
        countTranscripts()
        if selection == nil, rows.contains(where: { $0.id == t.id }) {
            selection = t.id
        }
    }

    /// Lists the section's transcripts that match the search. Unless asked
    /// to keep it, a selection that is no longer listed moves to the first row.
    private func listRows(keepingSelection: Bool = false) {
        guard let scope = section.scope else { return }
        rows = store.search(query, scope: scope)
        guard !keepingSelection else { return }
        if let selection, rows.contains(where: { $0.id == selection }) { return }
        selection = rows.first?.id
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
    /// Vocabulary (until Task 22) and Settings have none.
    func count(of section: Section, models: [ModelDescriptor]) -> Int? {
        switch section {
        case .all, .today, .pinned: counts[section]
        case .models: models.isEmpty ? nil : models.filter { $0.state == .ready }.count
        case .vocabulary, .settings: nil
        }
    }

    /// The transcript the detail shows, if it is listed.
    var selectedTranscript: Transcript? {
        guard let selection else { return nil }
        return rows.first { $0.id == selection }
    }

    /// Moves the selection `step` rows down, or up when negative, stopping
    /// at either end. With nothing selected, down selects the first row and
    /// up the last.
    func moveSelection(by step: Int) {
        guard !rows.isEmpty else { return }
        guard let selection, let index = rows.firstIndex(where: { $0.id == selection }) else {
            self.selection = (step < 0 ? rows.last : rows.first)?.id
            return
        }
        self.selection = rows[min(max(index + step, 0), rows.count - 1)].id
    }

    // MARK: - What the list says

    /// What the list shows instead of rows; nil when it has rows. A store
    /// that cannot be opened says so whatever the search (Review Focus 5).
    var emptyMessage: String? {
        if case .unavailable(let message) = store.health { return message }
        guard rows.isEmpty else { return nil }
        if !query.isEmpty { return "No transcripts match “\(query)”." }
        let anyKept = (counts[.all] ?? 0) > 0
        switch section {
        case .today where anyKept: return "Nothing dictated today."
        case .pinned where anyKept: return "No pinned transcripts."
        default: return "Nothing dictated yet. Hold Globe and speak."
        }
    }

    /// Ruling T18-1: once a damaged store was moved aside and a new one
    /// started, the words saying so, shown above the list, which works as usual.
    var notice: String? {
        guard case .recovered(let message) = store.health else { return nil }
        return message
    }

    /// What ⌘C copies: the selected part of the detail's text, or else the
    /// whole selected transcript; nil when it has no text (Ruling T18-3).
    var copyCommandText: String? {
        guard let t = selectedTranscript else { return nil }
        return Self.textToCopy(t.text, selectedRange: textSelection)
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

    /// The detail's four facts. `models` (as `AppModel.models` lists them)
    /// name the model; one not listed shows its storage key. A time the
    /// transcript does not know (imported history, a failed dictation's
    /// transcription) reads "—".
    nonisolated static func facts(_ t: Transcript, models: [ModelDescriptor] = []) -> [(label: String, value: String)] {
        [("Length", tenths(t.recordingSeconds)),
         ("Transcribed in", tenths(t.transcribeSeconds)),
         ("Model", modelName(t.modelKey, in: models)),
         ("Words", String(t.text.split(whereSeparator: \.isWhitespace).count))]
    }

    /// Seconds to a tenth, "14.2s"; "—" when not known.
    private nonisolated static func tenths(_ seconds: Double) -> String {
        seconds > 0 && seconds.isFinite ? String(format: "%.1fs", seconds) : "—"
    }

    /// A model's display name from `models`, or its storage key when it is not listed.
    nonisolated static func modelName(_ storageKey: String, in models: [ModelDescriptor]) -> String {
        models.first { $0.id.storageKey == storageKey }?.displayName ?? storageKey
    }

    /// The status in a word: status is words, never colour (Prism).
    nonisolated static func statusWord(_ t: Transcript) -> String {
        switch t.status {
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
}
