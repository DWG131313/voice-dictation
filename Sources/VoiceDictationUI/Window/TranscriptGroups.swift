import Foundation
import VoiceDictationLib

/// One place's transcripts within one day, newest first.
struct PlaceGroup: Identifiable {
    let place: Place
    let transcripts: [Transcript]
    /// "\(day id)|\(app)|\(project)"; unique across the list.
    let id: String
}

/// One calendar day's transcripts, split by place.
struct DayGroup: Identifiable {
    let day: Date
    let groups: [PlaceGroup]
    /// "day-YYYY-MM-DD" in the calendar that grouped it.
    let id: String

    var transcripts: [Transcript] { groups.flatMap(\.transcripts) }
}

/// Rows into days, then into the folder or app they were dictated in, and
/// the words for each heading.
enum TranscriptGroups {
    /// `rows` come newest first. Days turn at midnight in `calendar`'s time
    /// zone; within a day, groups sit in the order their newest row appears.
    static func days(_ rows: [Transcript], calendar: Calendar = .current) -> [DayGroup] {
        var dayOrder: [String] = []
        var dayStart: [String: Date] = [:]
        var placeOrder: [String: [Place]] = [:]
        var byPlace: [String: [Place: [Transcript]]] = [:]

        for row in rows {
            let id = dayID(row.date, calendar: calendar)
            let place = Place(row)
            if dayStart[id] == nil {
                dayOrder.append(id)
                dayStart[id] = calendar.startOfDay(for: row.date)
            }
            if byPlace[id, default: [:]][place] == nil { placeOrder[id, default: []].append(place) }
            byPlace[id, default: [:]][place, default: []].append(row)
        }

        return dayOrder.map { id in
            let groups = (placeOrder[id] ?? []).map { place in
                PlaceGroup(place: place, transcripts: byPlace[id]?[place] ?? [],
                           id: "\(id)|\(place.app ?? "")|\(place.project ?? "")")
            }
            return DayGroup(day: dayStart[id] ?? Date(), groups: groups, id: id)
        }
    }

    /// "Today", "Yesterday", "Sun, Nov 15", with the year when it is not
    /// `now`'s: "Sat, Nov 15, 2025". Tests pass their own calendar and locale.
    static func dayTitle(_ day: Date, now: Date, calendar: Calendar = .current,
                         locale: Locale = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).month(.abbreviated).day()
        let thisYear = calendar.isDate(day, equalTo: now, toGranularity: .year)
        return day.formatted(thisYear ? style : style.year())
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// A group's heading: the folder, with the app beside it; an app alone
    /// when no folder was recorded.
    static func title(of place: Place) -> (name: String, app: String?) {
        let app = place.app ?? "Unknown app"
        guard let project = place.project else { return (app, nil) }
        return (project, app)
    }

    private static func dayID(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "day-%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
