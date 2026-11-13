import XCTest
@testable import VoiceDictationLib

final class StageTimerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testMillisecondsBetweenMarks() {
        var timer = StageTimer()
        timer.mark(.keyDown, at: t0)
        timer.mark(.firstAudio, at: t0.addingTimeInterval(0.25))
        XCTAssertEqual(timer.milliseconds(from: .keyDown, to: .firstAudio), 250)
    }

    func testMissingStageReturnsNil() {
        var timer = StageTimer()
        timer.mark(.keyDown, at: t0)
        XCTAssertNil(timer.milliseconds(from: .keyDown, to: .pasted))
        XCTAssertNil(timer.milliseconds(from: .keyUp, to: .keyDown))
    }

    func testSummaryFormat() {
        var timer = StageTimer()
        timer.mark(.keyDown, at: t0)
        timer.mark(.firstAudio, at: t0.addingTimeInterval(0.120))
        timer.mark(.keyUp, at: t0.addingTimeInterval(3.0))
        timer.mark(.textReady, at: t0.addingTimeInterval(3.8))
        timer.mark(.pasted, at: t0.addingTimeInterval(3.815))
        XCTAssertEqual(timer.summary, "keyDown→firstAudio=120ms keyUp→text=800ms text→pasted=15ms")
    }

    /// Ruling P5: when cleanup ran, its interval comes last, so the first
    /// three figures read as they always have (Danny's D8 baseline).
    /// `text→pasted` still runs from the text to the paste, cleanup included.
    func testSummaryAddsTheCleanupIntervalWhenCleanupRan() {
        var timer = StageTimer()
        timer.mark(.keyDown, at: t0)
        timer.mark(.firstAudio, at: t0.addingTimeInterval(0.120))
        timer.mark(.keyUp, at: t0.addingTimeInterval(3.0))
        timer.mark(.textReady, at: t0.addingTimeInterval(3.8))
        timer.mark(.cleaned, at: t0.addingTimeInterval(4.4))
        timer.mark(.pasted, at: t0.addingTimeInterval(4.415))
        XCTAssertEqual(timer.summary, "keyDown→firstAudio=120ms keyUp→text=800ms text→pasted=615ms text→cleaned=600ms")
    }
}
