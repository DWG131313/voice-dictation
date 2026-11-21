import XCTest
@testable import VoiceDictationLib
@testable import VoiceDictationUI

/// Grouping rows into days, then places, and the words for each heading.
final class TranscriptGroupsTests: XCTestCase {
    private let la: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    private let enUS = Locale(identifier: "en_US")

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        la.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func row(_ date: Date, app: String? = nil, project: String? = nil) -> Transcript {
        Transcript(date: date, text: "t", rawText: "t", appName: app, project: project, modelKey: "m",
                   recordingSeconds: 1, transcribeSeconds: 1, statusRaw: "pasted")
    }

    private var now: Date { date(2026, 11, 21, 12) }

    func testDaysSplitAtMidnightInTheCalendarsTimeZone() {
        let at0001 = row(date(2026, 11, 21, 0, 1))
        let at2359 = row(date(2026, 11, 20, 23, 59))
        let days = TranscriptGroups.days([at0001, at2359], calendar: la)
        XCTAssertEqual(days.map { $0.transcripts.map(\.id) }, [[at0001.id], [at2359.id]])
        XCTAssertEqual(days.map(\.id), ["day-2026-11-21", "day-2026-11-20"])
    }

    func testGroupsAreOrderedByTheirNewestTranscript() throws {
        let notes1010 = row(date(2026, 11, 21, 10, 10), app: "Notes")
        let vd1005 = row(date(2026, 11, 21, 10, 5), app: "Terminal", project: "Voice Dictation")
        let notes1000 = row(date(2026, 11, 21, 10, 0), app: "Notes")
        let day = try XCTUnwrap(TranscriptGroups.days([notes1010, vd1005, notes1000], calendar: la).first)
        XCTAssertEqual(day.groups.map(\.place),
                       [Place(app: "Notes", project: nil), Place(app: "Terminal", project: "Voice Dictation")])
        XCTAssertEqual(day.groups[0].transcripts.map(\.id), [notes1010.id, notes1000.id])
        XCTAssertEqual(day.groups[1].id, "day-2026-11-21|Terminal|Voice Dictation")
    }

    func testAFolderInTwoAppsIsTwoGroups() throws {
        let a = row(date(2026, 11, 21, 10, 5), app: "Terminal", project: "X")
        let b = row(date(2026, 11, 21, 10, 0), app: "Code", project: "X")
        let day = try XCTUnwrap(TranscriptGroups.days([a, b], calendar: la).first)
        XCTAssertEqual(day.groups.count, 2)
    }

    func testUnknownAppsGroupTogether() throws {
        let a = row(date(2026, 11, 21, 10, 5), app: nil)
        let b = row(date(2026, 11, 21, 10, 0), app: "")
        let day = try XCTUnwrap(TranscriptGroups.days([a, b], calendar: la).first)
        XCTAssertEqual(day.groups.count, 1)
        XCTAssertEqual(TranscriptGroups.title(of: Place(app: nil, project: nil)).name, "Unknown app")
    }

    func testNoRowsNoDays() {
        XCTAssertTrue(TranscriptGroups.days([], calendar: la).isEmpty)
    }

    func testDayTitles() {
        func title(_ d: Date) -> String {
            TranscriptGroups.dayTitle(d, now: now, calendar: la, locale: enUS)
        }
        XCTAssertEqual(title(date(2026, 11, 21, 0, 1)), "Today")
        XCTAssertEqual(title(date(2026, 11, 20, 23, 59)), "Yesterday")
        XCTAssertEqual(title(date(2026, 11, 15)), "Sun, Nov 15")
        XCTAssertEqual(title(date(2025, 11, 15)), "Sat, Nov 15, 2025")
    }

    func testGroupTitles() {
        XCTAssertTrue(TranscriptGroups.title(of: Place(app: "Terminal", project: "Voice Dictation"))
                      == ("Voice Dictation", "Terminal"))
        XCTAssertTrue(TranscriptGroups.title(of: Place(app: "Notes", project: nil)) == ("Notes", nil))
        XCTAssertTrue(TranscriptGroups.title(of: Place(app: nil, project: "X")) == ("X", "Unknown app"))
    }
}
