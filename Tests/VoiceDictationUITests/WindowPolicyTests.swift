import XCTest
@testable import VoiceDictationUI

/// What the app does when a window closes: back to the menu bar only, and
/// hand focus back, unless another window is still open.
final class WindowPolicyTests: XCTestCase {
    private let open = WindowSnapshot(isVisible: true, canBecomeMain: true)

    func testLastWindowClosingLeavesAndHides() {
        XCTAssertEqual(WindowPolicy.afterClose(windows: []), .leaveAndHide)
    }

    func testMainClosingWithSettingsOpenDoesNotHide() {
        XCTAssertEqual(WindowPolicy.afterClose(windows: [open]), .stayRegular)
    }

    func testWelcomeOpenDoesNotHide() {
        XCTAssertEqual(WindowPolicy.afterClose(windows: [open, open]), .stayRegular)
    }

    func testWindowsThatCannotBeMainOrAreHiddenDoNotCount() {
        let panel = WindowSnapshot(isVisible: true, canBecomeMain: false)   // the menu bar menu's panel
        let hidden = WindowSnapshot(isVisible: false, canBecomeMain: true)  // a window already closed
        XCTAssertEqual(WindowPolicy.afterClose(windows: [panel, hidden]), .leaveAndHide)
    }
}
