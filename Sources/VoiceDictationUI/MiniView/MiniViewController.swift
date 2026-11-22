import AppKit
import SwiftUI
import VoiceDictationLib

/// The mini view as `AppModel` drives it: `MiniViewController` in the app, a
/// fake in tests.
@MainActor
protocol MiniViewPresenting: AnyObject {
    /// Whether the tab is on screen. The bottom pill stays hidden while it is.
    var isShowingTab: Bool { get }
    /// Called each time `isShowingTab` changes.
    var onTabShownOrHidden: (() -> Void)? { get set }
    /// What the panel shows and does: the newest transcript with text, its
    /// Copy, and Open, which brings up the main window.
    func connect(latest: @escaping () -> Transcript?, copy: @escaping (Transcript) -> Void,
                 openMainWindow: @escaping () -> Void)
    /// "Mini View" switched on or off.
    func setEnabled(_ enabled: Bool)
    /// The work under way changed (`DictationPipeline.work`).
    func workChanged(_ work: DictationState)
    /// A slice's peak, at the time it was captured, as the pill hears it.
    func heard(peak: Float, at time: TimeInterval)
    /// A dictation ended: pasted, left on the clipboard, or failed.
    func finished(_ outcome: DictationOutcome)
}

/// The mini view: a tab on the edge of the window in front saying what
/// dictation is doing, and the panel a click on it opens. The tab follows the
/// window as the tracker reports it, through macOS's notifications and never
/// a timer; the one wake-up it schedules is for a word going stale. Neither
/// window activates the app; only the panel's Open does, on purpose.
@MainActor
final class MiniViewController: MiniViewPresenting {
    private(set) var isShowingTab = false
    var onTabShownOrHidden: (() -> Void)?
    /// The last dictation to end, and the window in front when it did. In
    /// memory only.
    private(set) var result: MiniTabResult?

    private let tracker: FrontWindowWatching
    private let preferences: PreferencesManager
    /// False in tests: nothing goes on screen, no mouse monitor is installed
    /// and no wake-up is scheduled.
    private let showsWindows: Bool
    private var isEnabled = false
    /// The window the tab sits on; nil while it is hidden.
    private var window: FrontWindow?
    private var work: DictationState = .idle
    /// The tab's live line, started again for each new recording.
    private var line = LevelLine(.tab)
    /// When the recording `line` belongs to started.
    private var recordingStart: Date?
    private var latest: () -> Transcript? = { nil }
    private var copy: (Transcript) -> Void = { _ in }
    private var openMainWindow: () -> Void = {}
    /// Draws the tab again when the result's word goes stale.
    private var wakeUp: Task<Void, Never>?
    private var isPanelOpen = false
    /// Closes the panel on a click in another app; installed only while it is open.
    private var outsideClicks: Any?
    /// Made when first shown.
    private var tabPanel: MiniTabPanel?
    private var infoPanel: MiniInfoPanel?
    /// Measured when the tab first shows, once the app has registered its fonts.
    private lazy var tabHeight = MiniTabView.height()

    init(tracker: FrontWindowWatching, preferences: PreferencesManager, showsWindows: Bool = true) {
        self.tracker = tracker
        self.preferences = preferences
        self.showsWindows = showsWindows
        tracker.onChange = { [weak self] window in self?.frontWindowChanged(window) }
    }

    /// The side every window has the tab on, as saved.
    private var side: MiniViewSide { preferences.miniViewOnLeft ? .left : .right }

    func connect(latest: @escaping () -> Transcript?, copy: @escaping (Transcript) -> Void,
                 openMainWindow: @escaping () -> Void) {
        self.latest = latest
        self.copy = copy
        self.openMainWindow = openMainWindow
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            // Reports the window in front through `onChange`.
            tracker.start()
        } else {
            // Stopping is quiet: no `onChange`, so the tab goes here.
            tracker.stop()
            show(on: nil)
        }
    }

    /// A new recording starts a new line and closes the panel.
    func workChanged(_ work: DictationState) {
        self.work = work
        if case .recording(let since) = work, since != recordingStart {
            recordingStart = since
            line.reset()
            closePanel()
            endOldWord()
        }
        draw()
    }

    /// A new take ends the last word ("or sooner when the next dictation
    /// starts"), so a take with no outcome cannot bring it back. The time stays
    /// on its window; only the word's age is made past.
    private func endOldWord() {
        wakeUp?.cancel()
        guard let old = result else { return }
        result = MiniTabResult(status: old.status, dictated: old.dictated, arrived: .distantPast, window: old.window)
    }

    func heard(peak: Float, at time: TimeInterval) {
        line.add(peak: peak, at: time)
        if case .recording = work { draw() }
    }

    /// The result belongs to the window in front now, as the text pasted;
    /// switching windows later does not move it.
    func finished(_ outcome: DictationOutcome) {
        record(outcome.status, dictated: outcome.date)
        if isPanelOpen { showPanel() }
    }

    /// The panel's Copy: the newest transcript with text on the clipboard,
    /// and the tab says Copied on the window in front, as when a paste could
    /// not go through (spec, Call 3).
    func copyLatest() {
        guard let transcript = latest() else { return }
        copy(transcript)
        record(.copied, dictated: transcript.date)
    }

    /// A new result, for the window in front now: the tab shows it, and
    /// wakes when its word goes stale.
    private func record(_ status: DictationOutcome.Status, dictated: Date) {
        let now = Date()
        result = MiniTabResult(status: status, dictated: dictated, arrived: now, window: tracker.current?.id)
        draw()
        scheduleWakeUp(now: now)
    }

    /// The end of a drag: the side of the window the tab was let go nearer
    /// is saved, for every window, and the tab docks there.
    func dropped(atMidX x: CGFloat) {
        guard let window else { return }
        preferences.miniViewOnLeft = MiniViewLayout.side(droppedAt: x, window: window.frame) == .left
        show(on: window)
    }

    // MARK: - The tab

    private func frontWindowChanged(_ window: FrontWindow?) {
        guard isEnabled else { return }
        show(on: window)
    }

    /// Puts the tab beside `window`, or hides it, and the panel, with none.
    /// Another window closes the panel; the same one moved takes it along.
    private func show(on window: FrontWindow?) {
        if window?.id != self.window?.id { closePanel() }
        self.window = window
        if showsWindows {
            if let window {
                let tab = tabFrame(on: window)
                (tabPanel ?? makeTabPanel()).show(content(), at: tab)
                if isPanelOpen { infoPanel?.place(besideTab: tab, on: window) }
            } else {
                tabPanel?.hide()
            }
        }
        let showing = window != nil
        guard showing != isShowingTab else { return }
        isShowingTab = showing
        onTabShownOrHidden?()
    }

    private func makeTabPanel() -> MiniTabPanel {
        let panel = MiniTabPanel()
        panel.onClick = { [weak self] in self?.tabClicked() }
        panel.onDrop = { [weak self] x in self?.dropped(atMidX: x) }
        tabPanel = panel
        return panel
    }

    private func tabFrame(on window: FrontWindow) -> CGRect {
        MiniViewLayout.tabFrame(window: window.frame, side: side, tabHeight: tabHeight,
                                visibleFrame: window.visibleFrame)
    }

    private func content() -> MiniTabContent {
        MiniTabContent(work: work, result: result, window: window?.id, line: line, now: Date())
    }

    /// Draws the tab again where it is.
    private func draw() {
        guard showsWindows, window != nil else { return }
        tabPanel?.draw(content())
    }

    /// One wake-up, when the result's word goes stale (`MiniTab.nextChange`);
    /// a newer result replaces it.
    private func scheduleWakeUp(now: Date) {
        wakeUp?.cancel()
        guard showsWindows, let change = MiniTab.nextChange(result: result, now: now) else { return }
        wakeUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(change.timeIntervalSince(now)))
            guard !Task.isCancelled else { return }
            self?.draw()
        }
    }

    // MARK: - The panel

    /// A click on the tab opens the panel, or closes it.
    private func tabClicked() {
        if isPanelOpen {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        guard showsWindows, window != nil else { return }
        isPanelOpen = true
        showPanel()
        // Clicks in other apps only; clicks on the tab and the panel are this
        // app's own and reach them.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    /// The newest transcript, beside the tab.
    private func showPanel() {
        guard let window else { return }
        let view = MiniPanelView(transcript: latest(), now: Date(),
                                 copy: { [weak self] in self?.copyLatest() },
                                 open: { [weak self] in self?.openFromPanel() })
        let panel = infoPanel ?? MiniInfoPanel()
        infoPanel = panel
        panel.show(view, besideTab: tabFrame(on: window), on: window)
    }

    private func closePanel() {
        guard isPanelOpen else { return }
        isPanelOpen = false
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        infoPanel?.hide()
    }

    /// Open: the main window comes up, and the app with it.
    private func openFromPanel() {
        closePanel()
        openMainWindow()
    }
}
