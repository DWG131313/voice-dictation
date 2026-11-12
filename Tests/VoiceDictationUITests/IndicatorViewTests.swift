import XCTest
@testable import VoiceDictationLib
@testable import VoiceDictationUI

/// What the indicator says in each state, and its timer.
final class IndicatorViewTests: XCTestCase {
    func testWordsForEachState() {
        XCTAssertEqual(IndicatorView.words(for: .recording(since: Date())), "Listening")
        XCTAssertEqual(IndicatorView.words(for: .transcribing), "Transcribing")
        XCTAssertEqual(IndicatorView.words(for: .cleaning), "Cleaning up")
        // Anything else: hidden.
        let hidden: [DictationState] = [.idle, .preparingModel("Apple Speech"), .needsPermission("Microphone"), .error("Failed")]
        for state in hidden {
            XCTAssertNil(IndicatorView.words(for: state), "\(state)")
        }
    }

    func testTimerReadsMinutesAndSeconds() {
        XCTAssertEqual(IndicatorView.clock(0), "0:00")
        XCTAssertEqual(IndicatorView.clock(0.99), "0:00")
        XCTAssertEqual(IndicatorView.clock(6), "0:06")
        XCTAssertEqual(IndicatorView.clock(59.5), "0:59")
        XCTAssertEqual(IndicatorView.clock(60), "1:00")
        XCTAssertEqual(IndicatorView.clock(299), "4:59")
        XCTAssertEqual(IndicatorView.clock(300), "5:00")
        XCTAssertEqual(IndicatorView.clock(-1), "0:00")
    }
}
