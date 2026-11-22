import AppKit
import SwiftUI
import XCTest
import VoiceDictationLib
@testable import VoiceDictationUI

/// The indicator's window: never takes focus, floats over everything, sits at
/// the bottom centre of the screen with the mouse. No test shows it.
final class IndicatorPanelTests: XCTestCase {
    /// Global Constraints: the app being dictated into keeps focus.
    @MainActor
    func testThePanelNeverTakesFocus() {
        let panel = makePanel()
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.styleMask, [.borderless, .nonactivatingPanel])
        XCTAssertTrue(panel.ignoresMouseEvents)
    }

    /// Above other apps, full-screen ones too, on every Space; and still shown
    /// while the app is inactive or hidden (closing the last window hides it).
    @MainActor
    func testThePanelFloatsOverEverything() {
        let panel = makePanel()
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertEqual(panel.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary])
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.canHide)
        XCTAssertFalse(panel.hasShadow)
    }

    /// Clicking the mini view's tab or its panel leaves the app in front in
    /// front: neither activates VoiceDictation or takes the keyboard. Each
    /// still takes its first click, though the app is never active.
    @MainActor
    func testTheMiniViewPanelsNeverTakeFocus() {
        _ = NSApplication.shared
        let panels: [NSPanel] = [MiniTabPanel(), MiniInfoPanel()]
        for panel in panels {
            XCTAssertFalse(panel.canBecomeKey, "\(type(of: panel))")
            XCTAssertFalse(panel.canBecomeMain, "\(type(of: panel))")
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "\(type(of: panel))")
            XCTAssertFalse(panel.hidesOnDeactivate, "\(type(of: panel))")
            XCTAssertFalse(panel.hasShadow, "\(type(of: panel))")
            XCTAssertEqual(panel.contentView?.acceptsFirstMouse(for: nil), true, "\(type(of: panel))")
        }
    }

    func testItSitsAtTheBottomCentre80PointsUp() {
        let visible = NSRect(x: 0, y: 70, width: 1512, height: 875)   // above a Dock
        XCTAssertEqual(IndicatorPanel.frame(for: NSSize(width: 400, height: 50), in: visible),
                       NSRect(x: 556, y: 150, width: 400, height: 50))
        let second = NSRect(x: 1512, y: -200, width: 2560, height: 1415)
        XCTAssertEqual(IndicatorPanel.frame(for: NSSize(width: 401, height: 50), in: second),
                       NSRect(x: 2592, y: -120, width: 401, height: 50))
    }

    func testItGoesToTheScreenWithTheMouse() {
        let builtIn = (frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
                       visibleFrame: NSRect(x: 0, y: 70, width: 1512, height: 875))
        let external = (frame: NSRect(x: 1512, y: 0, width: 2560, height: 1440),
                        visibleFrame: NSRect(x: 1512, y: 0, width: 2560, height: 1415))
        let screens = [builtIn, external]

        XCTAssertEqual(IndicatorPanel.visibleFrame(containing: NSPoint(x: 2000, y: 700), among: screens),
                       external.visibleFrame)
        XCTAssertEqual(IndicatorPanel.visibleFrame(containing: NSPoint(x: 100, y: 100), among: screens),
                       builtIn.visibleFrame)
        // The mouse's y counts from 1, so at the very top of a screen it equals the frame's maxY.
        XCTAssertEqual(IndicatorPanel.visibleFrame(containing: NSPoint(x: 2000, y: 1440), among: screens),
                       external.visibleFrame)
        // On no screen: the first, which has the menu bar.
        XCTAssertEqual(IndicatorPanel.visibleFrame(containing: NSPoint(x: 100, y: 1200), among: screens),
                       builtIn.visibleFrame)
        XCTAssertNil(IndicatorPanel.visibleFrame(containing: .zero, among: []))
    }

    /// The panel keeps one size, the widest layout's; every state's box fits
    /// it and is as tall, so it sits on the same baseline 80 pt up.
    @MainActor
    func testEveryStateFitsThePanel() {
        Fonts.registerAll()
        let size = IndicatorPanel.indicatorSize()
        XCTAssertGreaterThan(size.width, LevelLine.width)

        for state in [DictationState.recording(since: Date()), .transcribing, .cleaning] {
            let box = NSHostingView(rootView: IndicatorView(state: state, level: LevelLine())).fittingSize
            XCTAssertLessThanOrEqual(box.width, size.width, "\(state)")
            XCTAssertEqual(box.height, size.height, "\(state)")
        }
    }

    @MainActor
    private func makePanel() -> IndicatorPanel {
        _ = NSApplication.shared
        return IndicatorPanel()
    }
}
