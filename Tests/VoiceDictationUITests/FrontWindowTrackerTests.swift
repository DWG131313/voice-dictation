import XCTest
@testable import VoiceDictationUI

final class FrontWindowTrackerTests: XCTestCase {
    func testTheTabSitsOnlyOnOrdinaryWindowsOfOtherApps() {
        XCTAssertTrue(FrontWindowTracker.shows(subrole: "AXStandardWindow", isFullScreen: false, isMinimized: false, isOwnApp: false))
        XCTAssertFalse(FrontWindowTracker.shows(subrole: "AXStandardWindow", isFullScreen: true, isMinimized: false, isOwnApp: false))
        XCTAssertFalse(FrontWindowTracker.shows(subrole: "AXStandardWindow", isFullScreen: false, isMinimized: true, isOwnApp: false))
        XCTAssertFalse(FrontWindowTracker.shows(subrole: "AXStandardWindow", isFullScreen: false, isMinimized: false, isOwnApp: true))
        XCTAssertFalse(FrontWindowTracker.shows(subrole: "AXDialog", isFullScreen: false, isMinimized: false, isOwnApp: false))
        XCTAssertFalse(FrontWindowTracker.shows(subrole: nil, isFullScreen: false, isMinimized: false, isOwnApp: false))
    }
}
