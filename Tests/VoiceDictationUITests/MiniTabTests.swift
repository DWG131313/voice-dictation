import XCTest
@testable import VoiceDictationLib
@testable import VoiceDictationUI

/// The tab's face, with a fixed locale, zone and clock so nothing depends on the machine.
final class MiniTabTests: XCTestCase {
    private let enUS = Locale(identifier: "en_US")
    private lazy var la: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()
    /// 2026-11-21 00:52 in Los Angeles.
    private lazy var t: Date = la.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 0, minute: 52))!
    private let here = WindowIdentity(pid: 1, token: 1)
    private let there = WindowIdentity(pid: 1, token: 2)

    private func face(_ work: DictationState, _ result: MiniTabResult? = nil, in window: WindowIdentity?,
                      at now: Date) -> MiniTabFace {
        MiniTab.face(work: work, result: result, window: window, now: now, calendar: la, locale: enUS)
    }

    func testRecordingShowsTheLiveSpectrumAndTheClock() {
        XCTAssertEqual(face(.recording(since: t), in: here, at: t + 4.2), MiniTabFace(mark: .liveSpectrum, time: "0:04"))
    }

    func testWorkInLineShowsTranscribing() {
        let working = MiniTabFace(mark: .flatSpectrum, word: "TRANSCRIBING", wordIsMuted: true)
        XCTAssertEqual(face(.transcribing, in: here, at: t), working)
        XCTAssertEqual(face(.cleaning, in: here, at: t).mark, .flatSpectrum)
    }

    func testPastedShowsInItsWindowForFourSeconds() {
        let pasted = MiniTabResult(status: .pasted, dictated: t, arrived: t, window: here)
        XCTAssertEqual(face(.idle, pasted, in: here, at: t + 1), MiniTabFace(mark: .split, time: "12:52", word: "PASTED"))
        XCTAssertEqual(face(.transcribing, pasted, in: here, at: t + 1).mark, .flatSpectrum,
                       "a dictation still in line keeps the tab working")
        XCTAssertEqual(face(.idle, pasted, in: here, at: t + 5), MiniTabFace(mark: .restLine, time: "12:52", timeIsMuted: true))
        XCTAssertEqual(face(.idle, pasted, in: there, at: t + 1), MiniTabFace(mark: .restLine),
                       "another window shows just the line")
    }

    func testCopiedStaysTenSeconds() {
        let copied = MiniTabResult(status: .copied, dictated: t, arrived: t, window: here)
        XCTAssertEqual(face(.idle, copied, in: here, at: t + 9),
                       MiniTabFace(mark: .restLine, time: "12:52", word: "COPIED", showsClipboard: true))
        XCTAssertNil(face(.idle, copied, in: here, at: t + 11).word)
    }

    func testFailedIsMutedForFourSeconds() {
        let failed = MiniTabResult(status: .failed, dictated: t, arrived: t, window: here)
        XCTAssertEqual(face(.idle, failed, in: here, at: t + 1),
                       MiniTabFace(mark: .restLine, time: "12:52", word: "FAILED", wordIsMuted: true))
    }

    func testNothingToShowIsTheRestLine() {
        let yesterday = MiniTabResult(status: .pasted, dictated: t - 86_400, arrived: t - 86_400, window: here)
        XCTAssertEqual(face(.idle, yesterday, in: here, at: t), MiniTabFace(mark: .restLine))
        XCTAssertEqual(face(.idle, nil, in: nil, at: t), MiniTabFace(mark: .restLine))
        XCTAssertEqual(face(.error("x"), nil, in: here, at: t), MiniTabFace(mark: .restLine))
    }

    func testNextChange() {
        let pasted = MiniTabResult(status: .pasted, dictated: t, arrived: t, window: here)
        let copied = MiniTabResult(status: .copied, dictated: t, arrived: t, window: here)
        XCTAssertEqual(MiniTab.nextChange(result: pasted, now: t + 1), t + 4)
        XCTAssertEqual(MiniTab.nextChange(result: copied, now: t + 1), t + 10)
        XCTAssertNil(MiniTab.nextChange(result: pasted, now: t + 5))
        XCTAssertNil(MiniTab.nextChange(result: nil, now: t))
    }

    func testClockTimeHasNoAMPMAndOnlyForToday() {
        XCTAssertEqual(MiniTab.clockTime(t, now: t, calendar: la, locale: enUS), "12:52")
        XCTAssertNil(MiniTab.clockTime(t - 86_400, now: t, calendar: la, locale: enUS))
    }
}
