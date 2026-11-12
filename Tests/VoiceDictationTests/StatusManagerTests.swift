import XCTest
@testable import VoiceDictationLib

/// How each model reads in the menu bar's Model submenu. Only the pure
/// helper is tested: a `StatusManager` itself puts an item in the menu bar.
final class StatusManagerTests: XCTestCase {
    func testReadyModelIsChosenByName() {
        let entry = StatusManager.menuEntry(for: model(.ready))
        XCTAssertEqual(entry.title, "Apple Speech")
        XCTAssertTrue(entry.isEnabled)
    }

    /// A model not on the Mac offers its download, which then selects it.
    func testNotDownloadedModelOffersDownload() {
        let entry = StatusManager.menuEntry(for: model(.notDownloaded))
        XCTAssertEqual(entry.title, "Download Apple Speech")
        XCTAssertTrue(entry.isEnabled)
    }

    func testPreparingModelCanStillBeChosen() {
        let entry = StatusManager.menuEntry(for: model(.preparing))
        XCTAssertEqual(entry.title, "Apple Speech — preparing")
        XCTAssertTrue(entry.isEnabled)
    }

    func testDownloadingModelShowsProgressAndWaits() {
        let entry = StatusManager.menuEntry(for: model(.downloading(0.42)))
        XCTAssertEqual(entry.title, "Apple Speech — downloading 42%")
        XCTAssertFalse(entry.isEnabled)
    }

    func testUnavailableModelSaysWhy() {
        let entry = StatusManager.menuEntry(for: model(.unavailable("Not supported on this Mac")))
        XCTAssertEqual(entry.title, "Apple Speech — Not supported on this Mac")
        XCTAssertFalse(entry.isEnabled)
    }

    private func model(_ state: ModelDescriptor.State) -> ModelDescriptor {
        ModelDescriptor(id: .appleSpeech, displayName: "Apple Speech", detail: "", state: state)
    }
}
