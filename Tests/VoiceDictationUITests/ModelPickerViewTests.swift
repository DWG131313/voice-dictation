import AppKit
import SwiftUI
import XCTest
import VoiceDictationLib
@testable import VoiceDictationUI

/// The pickers as AppKit draws them: the menu's rows (`NSHostingMenu`, the
/// bridge SwiftUI menus go through) and the sidebar's closed box. Both run
/// headless. Found by the final review: the rows had lost their line, and
/// "Slowest" read "Slow…".
@MainActor
final class ModelPickerViewTests: XCTestCase {
    private let tiny = ModelID(engine: .whisperCpp, name: "tiny.en")
    private let small = ModelID(engine: .whisperCpp, name: "small.en")
    private let large = ModelID(engine: .whisperKit, name: "large-v3-turbo")

    private func d(_ id: ModelID, _ name: String, _ state: ModelDescriptor.State = .ready) -> ModelDescriptor {
        ModelDescriptor(id: id, displayName: name, detail: "", state: state)
    }

    /// The line under each name is the menu item's subtitle: what the model
    /// trades, "in use", or what it is doing.
    func testEveryRowShowsItsLineUnderItsName() {
        let models = [d(tiny, "Fastest"), d(.whisperCppBase, "Fast"), d(small, "Slow", .notDownloaded),
                      d(large, "Slowest", .downloading(0.4)),
                      d(.appleSpeech, "Apple Speech", .unavailable("Not supported on this Mac"))]
        let menu = NSHostingMenu(rootView: ModelPickerItems(
            sections: ModelPicker.sections(models, selected: .whisperCppBase), choose: { _ in }))
        menu.update()

        let rows = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(rows.map(\.title), ["Fastest", "Fast", "Slow", "Slowest", "Apple Speech"])
        XCTAssertEqual(rows.map(\.subtitle), ["more mistakes", "in use", "fewer mistakes", "downloading 40%",
                                              "Not supported on this Mac"])
        XCTAssertEqual(rows.map(\.isEnabled), [true, true, true, false, false])
    }

    /// The closed box beside the Mini View switch fits every name on the
    /// speed ladder whole: a cut "Slowest" reads "Slow…", the wrong model.
    func testEveryLadderNameFitsTheSidebarBox() {
        Fonts.registerAll()
        let room = MainWindow.sidebarWidth - 2 * (Theme.Space.sm + Theme.Space.xs)
        for (id, name) in [(tiny, "Fastest"), (.whisperCppBase, "Fast"), (small, "Slow"), (large, "Slowest")] {
            let footer = SidebarFooter(models: [d(id, name)], selectedModel: id,
                                       miniViewEnabled: .constant(true), choose: { _ in })
            let width = NSHostingView(rootView: footer).fittingSize.width
            XCTAssertLessThanOrEqual(width, room, "\(name) needs \(width) pt; the box has \(room)")
        }
    }
}
