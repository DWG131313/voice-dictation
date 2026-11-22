import CoreGraphics
import XCTest
@testable import VoiceDictationLib
@testable import VoiceDictationUI

/// The mini view's rules, with a stand-in for the window tracker and
/// nothing on screen.
@MainActor
final class MiniViewControllerTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 945)
    private lazy var terminal = FrontWindow(id: WindowIdentity(pid: 10, token: 1),
                                            frame: CGRect(x: 100, y: 100, width: 800, height: 600), visibleFrame: screen)
    private lazy var notes = FrontWindow(id: WindowIdentity(pid: 20, token: 1),
                                         frame: CGRect(x: 300, y: 200, width: 600, height: 500), visibleFrame: screen)
    private lazy var watcher = FakeWindowWatcher()
    private let preferences = PreferencesManager(defaults: MemoryPreferenceStore())
    private var shownOrHiddenCalls = 0
    private lazy var controller: MiniViewController = {
        let controller = MiniViewController(tracker: watcher, preferences: preferences, showsWindows: false)
        controller.onTabShownOrHidden = { [unowned self] in shownOrHiddenCalls += 1 }
        return controller
    }()

    /// Stopping the tracker is quiet, so turning the mini view off hides the
    /// tab itself; turning it on again shows it on the window in front.
    func testTheTabShowsOnlyWhileOnAndAWindowIsInFront() {
        controller.setEnabled(true)
        watcher.send(terminal)
        XCTAssertTrue(controller.isShowingTab)
        watcher.send(nil)
        XCTAssertFalse(controller.isShowingTab)
        XCTAssertEqual(shownOrHiddenCalls, 2)

        watcher.send(terminal)
        controller.setEnabled(false)
        XCTAssertFalse(controller.isShowingTab)
        XCTAssertEqual(shownOrHiddenCalls, 4)

        controller.setEnabled(true)
        XCTAssertTrue(controller.isShowingTab, "the window in front is reported again")
        XCTAssertEqual(shownOrHiddenCalls, 5)
    }

    func testTheResultBelongsToTheWindowInFrontWhenItPasted() {
        controller.setEnabled(true)
        watcher.send(terminal)

        controller.finished(outcome(.pasted))

        XCTAssertEqual(controller.result?.window, terminal.id)
        XCTAssertEqual(controller.result?.status, .pasted)
        watcher.send(notes)
        XCTAssertEqual(controller.result?.window, terminal.id, "switching later does not move it")
    }

    /// Switching apps mid-dictation: the result belongs to the window in
    /// front when it pasted, and Pasted shows only there.
    func testSwitchingWindowsMidDictationPutsTheResultOnTheWindowThatPasted() {
        controller.setEnabled(true)
        watcher.send(terminal)
        controller.workChanged(.recording(since: Date()))
        watcher.send(notes)
        controller.workChanged(.transcribing)
        controller.finished(outcome(.pasted))
        controller.workChanged(.idle)

        XCTAssertEqual(controller.result?.window, notes.id)
        let now = Date()
        XCTAssertEqual(MiniTab.face(work: .idle, result: controller.result, window: notes.id, now: now).word, "PASTED")
        XCTAssertNotEqual(MiniTab.face(work: .idle, result: controller.result, window: terminal.id, now: now).word,
                          "PASTED")
    }

    /// A take that ends with no outcome (Escape, a tap, silence) must not
    /// bring back the last take's word: the new recording ends it, keeping
    /// the time on its window.
    func testARecordingWithNoOutcomeDoesNotBringBackTheOldWord() {
        controller.setEnabled(true)
        watcher.send(terminal)
        controller.finished(outcome(.pasted))

        controller.workChanged(.recording(since: Date()))
        controller.workChanged(.idle)

        let face = MiniTab.face(work: .idle, result: controller.result, window: terminal.id, now: Date())
        XCTAssertNil(face.word)
        XCTAssertEqual(face.mark, .restLine)
        XCTAssertNotNil(face.time, "the time stays on its window")
        XCTAssertTrue(face.timeIsMuted)
    }

    func testCopyFromThePanelCopiesTheNewestTranscript() {
        let newest = Transcript(date: Date(), text: "Hello there.", rawText: "Hello there.", appName: "Terminal",
                                modelKey: "m", recordingSeconds: 2, transcribeSeconds: 0.3, statusRaw: "pasted")
        var copied: [Transcript] = []
        controller.connect(latest: { newest }, copy: { copied.append($0) }, openMainWindow: {})

        controller.copyLatest()

        XCTAssertEqual(copied.map(\.id), [newest.id])
    }

    /// The panel's Copy says so on the tab, on the window in front, as a
    /// paste left on the clipboard does (spec, Call 3).
    func testCopyFromThePanelShowsCopiedOnTheWindowInFront() {
        let dictated = Date(timeIntervalSince1970: 1_763_700_000)
        let newest = Transcript(date: dictated, text: "Hello there.", rawText: "Hello there.", appName: "Terminal",
                                modelKey: "m", recordingSeconds: 2, transcribeSeconds: 0.3, statusRaw: "pasted")
        controller.connect(latest: { newest }, copy: { _ in }, openMainWindow: {})
        controller.setEnabled(true)
        watcher.send(terminal)

        controller.copyLatest()

        XCTAssertEqual(controller.result?.status, .copied)
        XCTAssertEqual(controller.result?.window, terminal.id)
        XCTAssertEqual(controller.result?.dictated, dictated)
    }

    func testCopyWithNothingDictatedCopiesNothing() {
        var copied: [Transcript] = []
        controller.connect(latest: { nil }, copy: { copied.append($0) }, openMainWindow: {})
        controller.setEnabled(true)
        watcher.send(terminal)
        controller.finished(outcome(.pasted))

        controller.copyLatest()

        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(controller.result?.status, .pasted, "the tab is left as it was")
    }

    func testDroppingTheTabLeftOfCentreSavesTheLeftSide() {
        controller.setEnabled(true)
        watcher.send(FrontWindow(id: terminal.id, frame: CGRect(x: 100, y: 100, width: 800, height: 600),
                                 visibleFrame: screen))

        controller.dropped(atMidX: 300)
        XCTAssertTrue(preferences.miniViewOnLeft)

        controller.dropped(atMidX: 700)
        XCTAssertFalse(preferences.miniViewOnLeft, "and right of centre, the right")
    }

    /// The panel's header names the app, then the folder; the app alone
    /// when no folder was recorded (Ruling: app first).
    func testThePanelHeaderReadsTheAppThenTheFolder() {
        let inFolder = Transcript(date: Date(), text: "t", rawText: "t", appName: "Terminal", project: "Voice Dictation",
                                  modelKey: "m", recordingSeconds: 1, transcribeSeconds: 0.1, statusRaw: "pasted")
        let noFolder = Transcript(date: Date(), text: "t", rawText: "t", appName: "Notes",
                                  modelKey: "m", recordingSeconds: 1, transcribeSeconds: 0.1, statusRaw: "pasted")

        XCTAssertEqual(MiniPanelView.header(inFolder), "Terminal · Voice Dictation")
        XCTAssertEqual(MiniPanelView.header(noFolder), "Notes")
    }

    private func outcome(_ status: DictationOutcome.Status) -> DictationOutcome {
        DictationOutcome(date: Date(), clip: nil, rawText: "Hello there.", text: "Hello there.", model: .appleSpeech,
                         transcribeSeconds: 0.3, appName: "Terminal", status: status)
    }
}
