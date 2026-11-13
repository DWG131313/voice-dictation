import Carbon.HIToolbox
import CoreGraphics
import IOKit.hidsystem
import XCTest
@testable import VoiceDictationLib

/// How the tap handles the events it is given (`ModifierKeyStrategy.handle`):
/// it reads each event as the rules need, takes their answers to the
/// delegate, and swallows only what they swallow. `HotkeyLogicTests` has the
/// rules themselves. The events are made here and never posted, and no
/// strategy is started, so no event tap is made.
final class ModifierKeyStrategyTests: XCTestCase {
    private let recording = DictationState.recording(since: Date(timeIntervalSince1970: 1_762_900_000))
    private let rightOptionDown = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICERALTKEYMASK))
    private let rightCommandDown = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | UInt64(NX_DEVICERCMDKEYMASK))

    // MARK: - Escape

    /// With Right Command held for a dictation, Escape carries Command, the
    /// hotkey's own modifier. The tap gives the rule its choice, so that reads
    /// as a plain Escape: it cancels everything and is swallowed.
    func testEscapeWithRightCommandHeldForTheHotkeyCancelsAndIsSwallowed() throws {
        let (strategy, delegate) = make(.rightCommand, state: recording)
        XCTAssertTrue(letsThrough(strategy, .flagsChanged, try event(.flagsChanged, key: kVK_RightCommand, flags: rightCommandDown)))
        XCTAssertFalse(letsThrough(strategy, .keyDown, try event(.keyDown, key: kVK_Escape, flags: rightCommandDown)), "swallowed")
        runMainQueue()
        XCTAssertEqual(delegate.calls, ["hotkeyDidStartPress", "escapePressedWhileWorking"])
    }

    // MARK: - Paste last (Ruling T23-1)

    /// Control-Option-V with its shortcut on is swallowed at once, but the
    /// paste waits until a modifier change shows neither Control nor Option
    /// down, so the app in front never sees them with the paste's Cmd+V.
    /// V let go first, then Option, then Control: it pastes at the last, once.
    func testPasteLastWaitsForControlAndOptionToBeLetGo() throws {
        let (strategy, delegate) = make(.globe, pasteLastShortcut: true)
        let controlOption: CGEventFlags = [.maskControl, .maskAlternate]
        XCTAssertTrue(letsThrough(strategy, .flagsChanged, try event(.flagsChanged, key: kVK_Control, flags: .maskControl)))
        XCTAssertTrue(letsThrough(strategy, .flagsChanged, try event(.flagsChanged, key: kVK_Option, flags: controlOption)))
        XCTAssertFalse(letsThrough(strategy, .keyDown, try event(.keyDown, key: kVK_ANSI_V, flags: controlOption)), "swallowed")
        runMainQueue()
        XCTAssertEqual(delegate.calls, [], "nothing yet: Control and Option are down")

        XCTAssertTrue(letsThrough(strategy, .flagsChanged, try event(.flagsChanged, key: kVK_Option, flags: .maskControl)))
        runMainQueue()
        XCTAssertEqual(delegate.calls, [], "Control is still down")

        XCTAssertTrue(letsThrough(strategy, .flagsChanged, try event(.flagsChanged, key: kVK_Control, flags: [])))
        runMainQueue()
        XCTAssertEqual(delegate.calls, ["pasteLastShortcutPressed"], "both let go: it pastes")

        XCTAssertTrue(letsThrough(strategy, .flagsChanged, try event(.flagsChanged, key: kVK_Shift, flags: .maskShift)))
        runMainQueue()
        XCTAssertEqual(delegate.calls, ["pasteLastShortcutPressed"], "once")
    }

    /// Control and Option kept down: the paste goes anyway at the cap
    /// (shortened here), once, and letting go later adds nothing.
    func testPasteLastGoesAnywayAtTheCapWhileTheKeysStayDown() throws {
        let (strategy, delegate) = make(.globe, pasteLastShortcut: true)
        strategy.pasteLastCap = 0.05
        let controlOption: CGEventFlags = [.maskControl, .maskAlternate]
        XCTAssertFalse(letsThrough(strategy, .keyDown, try event(.keyDown, key: kVK_ANSI_V, flags: controlOption)))
        runMainQueue()
        XCTAssertEqual(delegate.calls, [])

        let pasted = expectation(description: "past the cap")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { pasted.fulfill() }
        wait(for: [pasted], timeout: 2)
        XCTAssertEqual(delegate.calls, ["pasteLastShortcutPressed"], "the keys still down: it went anyway")

        XCTAssertTrue(letsThrough(strategy, .flagsChanged, try event(.flagsChanged, key: kVK_Option, flags: [])))
        runMainQueue()
        XCTAssertEqual(delegate.calls, ["pasteLastShortcutPressed"], "once")
    }

    // MARK: - Clicks

    /// Right Command held, then a click (Right Command+click opens a link
    /// in a new tab): the click goes through untouched, whichever button,
    /// and cancels that hold's dictation. While hands-free is locked a click
    /// cancels nothing.
    func testAClickWithRightCommandHeldGoesThroughAndCancelsTheHold() throws {
        for button in [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            let (strategy, delegate) = make(.rightCommand, state: recording)
            XCTAssertTrue(letsThrough(strategy, .flagsChanged, try event(.flagsChanged, key: kVK_RightCommand, flags: rightCommandDown)))
            XCTAssertTrue(letsThrough(strategy, button, try event(button, flags: rightCommandDown)), "\(button.rawValue) goes through")
            runMainQueue()
            XCTAssertEqual(delegate.calls, ["hotkeyDidStartPress", "hotkeyCancelled"], "\(button.rawValue)")
        }

        let (strategy, delegate) = make(.rightCommand, handsFree: true, state: recording)
        let now = ProcessInfo.processInfo.systemUptime
        for (time, flags) in [(now - 0.4, rightCommandDown), (now - 0.3, []), (now - 0.2, rightCommandDown), (now - 0.1, [])] {
            XCTAssertTrue(letsThrough(strategy, .flagsChanged, try event(.flagsChanged, key: kVK_RightCommand, flags: flags, at: time)))
        }
        XCTAssertTrue(letsThrough(strategy, .leftMouseDown, try event(.leftMouseDown)))
        runMainQueue()
        XCTAssertEqual(delegate.calls, ["hotkeyDidStartPress", "hotkeyDidTap", "hotkeyDidStartPress"], "locked: the click cancels nothing")
        XCTAssertEqual(strategy.tracker.hold, .locked)
    }

    /// Globe held, then a click: Globe+click is no shortcut, and holding
    /// Globe while clicking where the text should go is a way to dictate
    /// (Ruling T23-3). The tap gives the rule its choice, so the click goes
    /// through and cancels nothing, whichever button, and letting go of
    /// Globe ends the dictation as usual.
    func testAClickWithGlobeHeldGoesThroughAndKeepsDictating() throws {
        for button in [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            let (strategy, delegate) = make(.globe, state: recording)
            XCTAssertTrue(letsThrough(strategy, .flagsChanged, try event(.flagsChanged, key: kVK_Function, flags: .maskSecondaryFn)))
            XCTAssertTrue(letsThrough(strategy, button, try event(button, flags: .maskSecondaryFn)), "\(button.rawValue) goes through")
            runMainQueue()
            XCTAssertEqual(delegate.calls, ["hotkeyDidStartPress"], "\(button.rawValue): still dictating")
            XCTAssertTrue(letsThrough(strategy, .flagsChanged, try event(.flagsChanged, key: kVK_Function, flags: [])))
            runMainQueue()
            XCTAssertEqual(delegate.calls, ["hotkeyDidStartPress", "hotkeyDidEndPress"], "\(button.rawValue): let go")
        }
    }

    // MARK: - Shortcuts made with the hotkey (Ruling T23-2)

    /// While double-tap dictation records, two quick shortcuts made with the
    /// hotkey itself, Right Command+Z twice, are no double tap: the tap gives
    /// the rules every key-down, each press with a key during it is no tap,
    /// and the recording goes on. Nor is the second shortcut a first tap: a
    /// plain tap at once after it stops nothing, and the tap after that stops
    /// the recording.
    func testTwoShortcutsMadeWithTheHotkeyWhileLockedDoNotStopIt() throws {
        let (strategy, delegate) = make(.rightCommand, handsFree: true, state: recording)
        let now = ProcessInfo.processInfo.systemUptime
        func hotkey(down: Bool, secondsAgo: TimeInterval) throws {
            XCTAssertTrue(letsThrough(strategy, .flagsChanged, try event(.flagsChanged, key: kVK_RightCommand,
                                                                         flags: down ? rightCommandDown : [], at: now - secondsAgo)))
        }
        for (down, secondsAgo) in [(true, 2.0), (false, 1.9), (true, 1.7), (false, 1.6)] {
            try hotkey(down: down, secondsAgo: secondsAgo)
        }
        let locked = ["hotkeyDidStartPress", "hotkeyDidTap", "hotkeyDidStartPress"]
        for start in [1.0, 0.7] {
            try hotkey(down: true, secondsAgo: start)
            XCTAssertTrue(letsThrough(strategy, .keyDown, try event(.keyDown, key: kVK_ANSI_Z, flags: rightCommandDown)),
                          "Right Command+Z goes through")
            try hotkey(down: false, secondsAgo: start - 0.1)
        }
        runMainQueue()
        XCTAssertEqual(delegate.calls, locked, "two shortcuts: no stop")
        XCTAssertEqual(strategy.tracker.hold, .locked)

        try hotkey(down: true, secondsAgo: 0.4)
        try hotkey(down: false, secondsAgo: 0.3)
        runMainQueue()
        XCTAssertEqual(delegate.calls, locked, "a plain tap just after them is a first tap")
        try hotkey(down: true, secondsAgo: 0.2)
        try hotkey(down: false, secondsAgo: 0.1)
        runMainQueue()
        XCTAssertEqual(delegate.calls, locked + ["hotkeyDidEndPress"], "and the next one stops it")
    }

    // MARK: - A tap turned off

    /// macOS turned the tap off (its callback was slow, or the user asked),
    /// and the tap turns itself back on. Events went by meanwhile, so it
    /// catches up with the hotkey from the live modifier state (here a stand
    /// in): Right Option held, its release missed, and the dictation stops;
    /// still held, the dictation carries on, and its release stops it. The
    /// notice itself goes through.
    func testATapTurnedBackOnCatchesUpWithTheKey() throws {
        for disabled in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            let (released, releasedCalls) = make(.rightOption, state: recording)
            released.readLiveFlags = { [] }
            XCTAssertTrue(letsThrough(released, .flagsChanged, try event(.flagsChanged, key: kVK_RightOption, flags: rightOptionDown)))
            XCTAssertTrue(letsThrough(released, disabled, try event(.null)))
            runMainQueue()
            XCTAssertEqual(releasedCalls.calls, ["hotkeyDidStartPress", "hotkeyDidEndPress"], "\(disabled.rawValue): released")

            let (held, heldCalls) = make(.rightOption, state: recording)
            held.readLiveFlags = { [rightOptionDown] in rightOptionDown }
            XCTAssertTrue(letsThrough(held, .flagsChanged, try event(.flagsChanged, key: kVK_RightOption, flags: rightOptionDown)))
            XCTAssertTrue(letsThrough(held, disabled, try event(.null)))
            runMainQueue()
            XCTAssertEqual(heldCalls.calls, ["hotkeyDidStartPress"], "\(disabled.rawValue): still held")
            XCTAssertTrue(letsThrough(held, .flagsChanged, try event(.flagsChanged, key: kVK_RightOption, flags: [])))
            runMainQueue()
            XCTAssertEqual(heldCalls.calls, ["hotkeyDidStartPress", "hotkeyDidEndPress"], "\(disabled.rawValue): then let go")
        }
    }

    // MARK: - Timing

    /// The tap times a press by its events' own timestamps. With hands-free
    /// on, Right Option held for 1.1 s whose down and up are handled together,
    /// late (the main thread stalled), is still a hold: it dictates, and is
    /// not thrown away as a tap.
    func testALongPressWhoseEventsArriveLateIsStillAHold() throws {
        let (strategy, delegate) = make(.rightOption, handsFree: true, state: recording)
        let now = ProcessInfo.processInfo.systemUptime
        let down = try event(.flagsChanged, key: kVK_RightOption, flags: rightOptionDown, at: now - 1.2)
        let up = try event(.flagsChanged, key: kVK_RightOption, flags: [], at: now - 0.1)
        XCTAssertTrue(letsThrough(strategy, .flagsChanged, down))
        XCTAssertTrue(letsThrough(strategy, .flagsChanged, up))
        runMainQueue()
        XCTAssertEqual(delegate.calls, ["hotkeyDidStartPress", "hotkeyDidEndPress"])
    }

    // MARK: - Helpers

    /// Records what a strategy tells the app, in order.
    private final class RecordingDelegate: HotkeyDelegate {
        private(set) var calls: [String] = []
        func hotkeyDidStartPress() { calls.append("hotkeyDidStartPress") }
        func hotkeyDidEndPress() { calls.append("hotkeyDidEndPress") }
        func hotkeyCancelled() { calls.append("hotkeyCancelled") }
        func hotkeyDidTap() { calls.append("hotkeyDidTap") }
        func escapePressedWhileWorking() { calls.append("escapePressedWhileWorking") }
        func pasteLastShortcutPressed() { calls.append("pasteLastShortcutPressed") }
    }

    /// A strategy that is never started, so it has no tap, telling a
    /// recording delegate. The delegate is returned too: the strategy holds
    /// it weakly.
    private func make(_ choice: HotkeyChoice, handsFree: Bool = false, pasteLastShortcut: Bool = false,
                      state: DictationState = .idle) -> (ModifierKeyStrategy, RecordingDelegate) {
        let strategy = ModifierKeyStrategy(choice: choice, handsFree: { handsFree },
                                           pasteLastShortcut: { pasteLastShortcut }, appState: { state })
        let delegate = RecordingDelegate()
        strategy.delegate = delegate
        return (strategy, delegate)
    }

    /// An event as the tap would be given it, made and never posted. `time`
    /// is its timestamp in seconds since startup, now unless told.
    private func event(_ type: CGEventType, key: Int = 0, flags: CGEventFlags = [],
                       at time: TimeInterval? = ProcessInfo.processInfo.systemUptime,
                       sourceUserData: Int64 = 0) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.type = type
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(key))
        event.setIntegerValueField(.eventSourceUserData, value: sourceUserData)
        event.flags = flags
        if let time { event.timestamp = CGEventTimestamp(time * 1_000_000_000) }
        return event
    }

    /// Whether the strategy lets `event` through untouched: it hands back
    /// that same event, unretained, so this compares it while it is alive.
    private func letsThrough(_ strategy: ModifierKeyStrategy, _ type: CGEventType, _ event: CGEvent) -> Bool {
        strategy.handle(type, event)?.takeUnretainedValue() === event
    }

    /// Runs what the strategy queued for the main queue: it tells the
    /// delegate there, once it has answered the event.
    private func runMainQueue() {
        let ran = expectation(description: "the main queue has run what was queued before")
        DispatchQueue.main.async { ran.fulfill() }
        wait(for: [ran], timeout: 2)
    }
}
