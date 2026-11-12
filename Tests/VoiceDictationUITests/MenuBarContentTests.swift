import XCTest
import VoiceDictationLib
@testable import VoiceDictationUI

/// What the menu bar shows: its icon, the status line and the Model submenu.
/// Only the pure helpers are tested; the views themselves need the menu bar.
final class MenuBarContentTests: XCTestCase {
    private let everyState: [DictationState] = [
        .idle, .recording(since: Date()), .transcribing, .cleaning,
        .preparingModel("Apple Speech"), .error("Microphone in use by another app"), .needsPermission("Accessibility"),
    ]

    // MARK: - The Model submenu's entries (moved from StatusManagerTests)

    func testReadyModelIsChosenByName() {
        let entry = MenuBarContent.menuEntry(for: model(.ready))
        XCTAssertEqual(entry.title, "Apple Speech")
        XCTAssertTrue(entry.isEnabled)
    }

    /// A model not on the Mac offers its download, which then selects it.
    func testNotDownloadedModelOffersDownload() {
        let entry = MenuBarContent.menuEntry(for: model(.notDownloaded))
        XCTAssertEqual(entry.title, "Download Apple Speech")
        XCTAssertTrue(entry.isEnabled)
    }

    func testPreparingModelCanStillBeChosen() {
        let entry = MenuBarContent.menuEntry(for: model(.preparing))
        XCTAssertEqual(entry.title, "Apple Speech — preparing")
        XCTAssertTrue(entry.isEnabled)
    }

    func testDownloadingModelShowsProgressAndWaits() {
        let entry = MenuBarContent.menuEntry(for: model(.downloading(0.42)))
        XCTAssertEqual(entry.title, "Apple Speech — downloading 42%")
        XCTAssertFalse(entry.isEnabled)
    }

    func testUnavailableModelSaysWhy() {
        let entry = MenuBarContent.menuEntry(for: model(.unavailable("Not supported on this Mac")))
        XCTAssertEqual(entry.title, "Apple Speech — Not supported on this Mac")
        XCTAssertFalse(entry.isEnabled)
    }

    // MARK: - The submenu's layout

    /// One group per engine, in the order the service lists them; the old
    /// whisper-cli models sit under a "Previous engine" header.
    func testModelsAreGroupedByEngineWithTheOldEngineLabelled() {
        let sections = MenuBarContent.modelSections(models)

        XCTAssertEqual(sections.map(\.engine), [.appleSpeech, .whisperKit, .whisperCLI])
        XCTAssertEqual(sections.map(\.header), [nil, nil, "Previous engine"])
        XCTAssertEqual(sections.map { $0.models.map(\.displayName) },
                       [["Apple Speech", "Apple Dictation"], ["tiny.en", "base.en"], ["Base (English)"]])
    }

    func testModelSubmenuIsTitledWithTheModelInUse() {
        XCTAssertEqual(MenuBarContent.modelMenuTitle(models: models, selected: .appleDictation), "Model: Apple Dictation")
        // A saved choice no engine lists any more still says what it is.
        XCTAssertEqual(MenuBarContent.modelMenuTitle(models: models, selected: ModelID(engine: .whisperKit, name: "gone")),
                       "Model: whisperKit/gone")
        // Before the models are first listed.
        XCTAssertEqual(MenuBarContent.modelMenuTitle(models: [], selected: nil), "Model")
    }

    // MARK: - The status line

    /// Status is words (Prism): the status line says what the icon cannot.
    func testStatusLineSaysWhatTheAppIsDoing() {
        XCTAssertEqual(everyState.map(MenuBarContent.statusLine(for:)), [
            "Status: Ready", "Status: Recording...", "Status: Transcribing...", "Status: Cleaning up...",
            "Status: Preparing Apple Speech...", "Error: Microphone in use by another app",
            "Permission needed: Accessibility",
        ])
    }

    // MARK: - The icon

    /// Today's symbols, as the old menu bar item drew them.
    func testIconKeepsTodaysSymbols() {
        XCTAssertEqual(everyState.map { MenuBarLabel.symbolName(for: $0, exists: { _ in true }) }, [
            "mic.fill", "mic.fill", "waveform", "waveform", "arrow.down.circle", "mic.slash.fill",
            "exclamationmark.triangle.fill",
        ])
    }

    /// A symbol missing on this macOS would leave no icon at all.
    func testMissingSymbolFallsBackToTheMic() {
        XCTAssertEqual(MenuBarLabel.symbolName(for: .transcribing, exists: { $0 == "mic.fill" }), "mic.fill")
        XCTAssertEqual(MenuBarLabel.symbolName(for: .error("x"), exists: { $0 == "mic.fill" }), "mic.fill")
    }

    /// On this Mac every symbol exists, so none falls back.
    func testEverySymbolExistsHere() {
        XCTAssertEqual(everyState.map { MenuBarLabel.symbolName(for: $0) },
                       everyState.map { MenuBarLabel.symbolName(for: $0, exists: { _ in true }) })
    }

    func testIconIsNamedForVoiceOver() {
        XCTAssertEqual(everyState.map(MenuBarLabel.accessibilityLabel(for:)), [
            "VoiceDictation — Ready", "VoiceDictation — Recording", "VoiceDictation — Transcribing",
            "VoiceDictation — Cleaning up", "VoiceDictation — Preparing a model", "VoiceDictation — Error",
            "VoiceDictation — Permission Needed",
        ])
    }

    // MARK: - Helpers

    private func model(_ state: ModelDescriptor.State) -> ModelDescriptor {
        ModelDescriptor(id: .appleSpeech, displayName: "Apple Speech", detail: "", state: state)
    }

    private var models: [ModelDescriptor] {
        [
            ModelDescriptor(id: .appleSpeech, displayName: "Apple Speech", detail: "", state: .ready),
            ModelDescriptor(id: .appleDictation, displayName: "Apple Dictation", detail: "", state: .notDownloaded),
            ModelDescriptor(id: ModelID(engine: .whisperKit, name: "openai_whisper-tiny.en"), displayName: "tiny.en",
                            detail: "", state: .ready),
            ModelDescriptor(id: ModelID(engine: .whisperKit, name: "openai_whisper-base.en"), displayName: "base.en",
                            detail: "", state: .notDownloaded),
            ModelDescriptor(id: ModelID(engine: .whisperCLI, name: "base.en"), displayName: "Base (English)",
                            detail: "", state: .ready),
        ]
    }
}
