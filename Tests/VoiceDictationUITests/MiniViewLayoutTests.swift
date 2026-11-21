import XCTest
@testable import VoiceDictationUI

final class MiniViewLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let window = CGRect(x: 100, y: 100, width: 800, height: 600)

    func testTabBesideWindowOnEachSide() {
        XCTAssertEqual(MiniViewLayout.tabFrame(window: window, side: .right, tabHeight: 150, visibleFrame: screen),
                       CGRect(x: 900, y: 510, width: 40, height: 150))
        XCTAssertEqual(MiniViewLayout.tabFrame(window: window, side: .left, tabHeight: 150, visibleFrame: screen),
                       CGRect(x: 60, y: 510, width: 40, height: 150))
    }

    func testNoRoomOnTheRightFlipsToTheLeft() {
        let w = CGRect(x: 600, y: 100, width: 820, height: 600)
        XCTAssertEqual(MiniViewLayout.tabFrame(window: w, side: .right, tabHeight: 150, visibleFrame: screen).maxX, 600)
    }

    func testNoRoomEitherSideGoesJustInside() {
        let w = CGRect(x: 10, y: 100, width: 1420, height: 600)
        XCTAssertEqual(MiniViewLayout.tabFrame(window: w, side: .right, tabHeight: 150, visibleFrame: screen).maxX, 1430)
        XCTAssertEqual(MiniViewLayout.tabFrame(window: w, side: .left, tabHeight: 150, visibleFrame: screen).minX, 10)
    }

    func testNeverBelowTheScreen() {
        let w = CGRect(x: 100, y: 0, width: 800, height: 120)
        XCTAssertGreaterThanOrEqual(MiniViewLayout.tabFrame(window: w, side: .right, tabHeight: 150, visibleFrame: screen).minY, 0)
    }

    func testSecondScreenToTheRight() {
        let w = CGRect(x: 2000, y: 200, width: 800, height: 600)
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        XCTAssertEqual(MiniViewLayout.tabFrame(window: w, side: .right, tabHeight: 150, visibleFrame: second).minX, 2800)
    }

    func testPanelBeyondTheTabWhenItFits() {
        let tab = CGRect(x: 900, y: 510, width: 40, height: 150)
        XCTAssertEqual(MiniViewLayout.panelFrame(tab: tab, window: window, panelSize: CGSize(width: 248, height: 180), visibleFrame: screen),
                       CGRect(x: 940, y: 480, width: 248, height: 180))
    }

    func testPanelOverTheWindowWhenItDoesNotFit() {
        let edgeTab = CGRect(x: 1300, y: 510, width: 40, height: 150)
        let w = CGRect(x: 500, y: 100, width: 800, height: 600)
        XCTAssertEqual(MiniViewLayout.panelFrame(tab: edgeTab, window: w, panelSize: CGSize(width: 248, height: 180), visibleFrame: screen).maxX, 1300)
    }

    func testSideFollowsTheDropPoint() {
        let w = CGRect(x: 100, y: 100, width: 1400, height: 600)
        XCTAssertEqual(MiniViewLayout.side(droppedAt: 801, window: w), .right)
        XCTAssertEqual(MiniViewLayout.side(droppedAt: 799, window: w), .left)
    }

    func testAppKitFrameFlipsAccessibilityCoordinates() {
        XCTAssertEqual(MiniViewLayout.appKitFrame(axPosition: CGPoint(x: 100, y: 50), axSize: CGSize(width: 800, height: 600), primaryScreenHeight: 900),
                       CGRect(x: 100, y: 250, width: 800, height: 600))
    }
}
