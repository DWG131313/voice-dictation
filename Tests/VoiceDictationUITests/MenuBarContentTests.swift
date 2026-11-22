import Observation
import XCTest
import VoiceDictationLib
@testable import VoiceDictationUI

/// What the menu bar shows: its icon, the status line, the Model submenu and
/// Check for Updates….
/// Only the pure helpers are tested; the views themselves need the menu bar.
final class MenuBarContentTests: XCTestCase {
    private let everyState: [DictationState] = [
        .idle, .recording(since: Date()), .transcribing, .cleaning,
        .preparingModel("Apple Speech"), .error("Microphone in use by another app"), .needsPermission("Accessibility"),
    ]

    // MARK: - The Model submenu (its list is ModelPickerTests')

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

    // MARK: - Check for Updates…

    /// Choosing it asks Sparkle to check now, the app's only update check;
    /// building the menu checks nothing.
    @MainActor
    func testCheckForUpdatesChecksOnlyWhenChosen() {
        let updates = FakeUpdates()

        let entry = MenuBarContent.updatesEntry(updates)

        XCTAssertEqual(entry.title, "Check for Updates…")
        XCTAssertTrue(entry.isEnabled)
        XCTAssertEqual(updates.checks, 0)
        entry.action()
        XCTAssertEqual(updates.checks, 1)
    }

    /// Greyed out while Sparkle is already checking.
    @MainActor
    func testCheckForUpdatesWaitsWhileACheckIsUnderWay() {
        let updates = FakeUpdates()
        updates.canCheckForUpdates = false

        XCTAssertFalse(MenuBarContent.updatesEntry(updates).isEnabled)
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

    private var models: [ModelDescriptor] {
        [
            ModelDescriptor(id: .whisperCppBase, displayName: "whisper.cpp base.en", detail: "", state: .ready),
            ModelDescriptor(id: .appleSpeech, displayName: "Apple Speech", detail: "", state: .ready),
            ModelDescriptor(id: .appleDictation, displayName: "Apple Dictation", detail: "", state: .notDownloaded),
            ModelDescriptor(id: ModelID(engine: .whisperKit, name: "openai_whisper-tiny.en"), displayName: "tiny.en",
                            detail: "", state: .ready),
            ModelDescriptor(id: ModelID(engine: .whisperKit, name: "openai_whisper-base.en"), displayName: "base.en",
                            detail: "", state: .notDownloaded),
        ]
    }
}

/// Stands in for Sparkle, which only the app target links.
@MainActor @Observable
private final class FakeUpdates: UpdateChecking {
    var canCheckForUpdates = true
    private(set) var checks = 0

    func checkForUpdates() {
        checks += 1
    }
}
