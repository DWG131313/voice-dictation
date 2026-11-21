import Foundation
import VoiceDictationLib

/// What the tab draws in its mark's place.
enum MiniTabMark: Equatable {
    case restLine, liveSpectrum, flatSpectrum, split
}

/// Everything the tab shows at one moment.
struct MiniTabFace: Equatable {
    var mark: MiniTabMark
    var time: String? = nil
    var timeIsMuted = false
    var word: String? = nil
    var wordIsMuted = false
    var showsClipboard = false
}

/// The last dictation to finish: how it ended, when it was said, when its
/// outcome arrived, and the window that was in front then.
struct MiniTabResult: Equatable {
    let status: DictationOutcome.Status
    let dictated: Date
    let arrived: Date
    let window: WindowIdentity?
}

/// Which face the tab shows, and when it next changes.
enum MiniTab {
    static let pastedSeconds: TimeInterval = 4, copiedSeconds: TimeInterval = 10, failedSeconds: TimeInterval = 4

    /// The face for the pipeline's `work`, the last `result` and the `window`
    /// in front. Work still under way wins over any result; only the window the
    /// result belongs to shows it, and only for the day it was said.
    static func face(work: DictationState, result: MiniTabResult?, window: WindowIdentity?, now: Date,
                     calendar: Calendar = .current, locale: Locale = .current) -> MiniTabFace {
        switch work {
        case .recording(let since):
            return MiniTabFace(mark: .liveSpectrum, time: IndicatorView.clock(now.timeIntervalSince(since)))
        case .transcribing, .cleaning:
            return MiniTabFace(mark: .flatSpectrum, word: "TRANSCRIBING", wordIsMuted: true)
        case .idle, .preparingModel, .needsPermission, .error:
            break
        }
        guard let result, let window, result.window == window,
              let time = clockTime(result.dictated, now: now, calendar: calendar, locale: locale) else {
            return MiniTabFace(mark: .restLine)
        }
        let age = now.timeIntervalSince(result.arrived)
        let resting = MiniTabFace(mark: .restLine, time: time, timeIsMuted: true)
        switch result.status {
        case .pasted:
            return age < pastedSeconds ? MiniTabFace(mark: .split, time: time, word: "PASTED") : resting
        case .copied:
            return age < copiedSeconds
                ? MiniTabFace(mark: .restLine, time: time, word: "COPIED", showsClipboard: true) : resting
        case .failed:
            return age < failedSeconds
                ? MiniTabFace(mark: .restLine, time: time, word: "FAILED", wordIsMuted: true) : resting
        }
    }

    /// When the result's word goes stale; nil when it already has.
    static func nextChange(result: MiniTabResult?, now: Date) -> Date? {
        guard let result else { return nil }
        let seconds = switch result.status {
        case .pasted: pastedSeconds
        case .copied: copiedSeconds
        case .failed: failedSeconds
        }
        let end = result.arrived + seconds
        return end > now ? end : nil
    }

    /// "12:52": the time of day without AM or PM, for a `date` in `now`'s day;
    /// nil for any other day.
    static func clockTime(_ date: Date, now: Date, calendar: Calendar = .current,
                          locale: Locale = .current) -> String? {
        guard calendar.isDate(date, inSameDayAs: now) else { return nil }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits)
        // en_US may put a narrow no-break space in; DM Mono lacks it.
        return date.formatted(style).replacingOccurrences(of: "\u{202F}", with: " ")
    }
}
