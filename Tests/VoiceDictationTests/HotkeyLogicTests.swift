import Carbon.HIToolbox
import CoreGraphics
import IOKit.hidsystem
import XCTest
@testable import VoiceDictationLib

/// Task 23's hotkey rules, all pure: the keys to choose from and their
/// preferences, the press and release interpreter (`TapTracker`), which key a
/// modifier change is about (`HotkeyChoice`), and how the event tap answers
/// the hotkey and every other key-down (`ModifierKeyStrategy.action`). No
/// event tap is made and no event is posted.
final class HotkeyLogicTests: XCTestCase {
    private let escape = Int64(kVK_Escape)
    private let v = Int64(kVK_ANSI_V)
    private let controlOption: CGEventFlags = [.maskControl, .maskAlternate]
    private let otherKeys = [kVK_RightArrow, kVK_ANSI_A, kVK_Space, kVK_Return, kVK_Delete].map(Int64.init)
    private let recording = DictationState.recording(since: Date(timeIntervalSince1970: 1_762_900_000))
    private var working: [DictationState] { [recording, .transcribing, .cleaning] }
    private let notWorking: [DictationState] = [
        .idle, .preparingModel("Apple Speech"), .needsPermission("Microphone"), .error("Microphone in use by another app"),
    ]

    // MARK: - Holding

    func testHoldStartsOnDownAndStopsOnUp() {
        for isOn in [false, true] {
            var tracker = TapTracker(doubleTapEnabled: isOn)
            XCTAssertEqual(tracker.down(at: 10), .start, "double-tap dictation \(isOn)")
            XCTAssertEqual(tracker.hold, .held)
            XCTAssertEqual(tracker.up(at: 11), .stop, "double-tap dictation \(isOn)")
            XCTAssertEqual(tracker.hold, .none)
        }
    }

    /// Double-tap dictation off, nothing changes: two quick taps are two
    /// recordings, each too short for the recorder's 0.5 s rule, which
    /// throws them away as it always has.
    func testDoubleTapOffTwoQuickTapsAreTwoShortRecordings() {
        var tracker = TapTracker(doubleTapEnabled: false)
        for (down, up) in [(0.0, 0.1), (0.2, 0.3)] {
            XCTAssertEqual(tracker.down(at: down), .start)
            XCTAssertEqual(tracker.up(at: up), .stop)
            XCTAssertEqual(AudioRecorder.verdict(duration: up - down, peak: 0.5), .tooShort)
        }
        XCTAssertEqual(tracker.hold, .none, "no lock with double-tap dictation off")
    }

    // MARK: - Double-tap dictation

    /// Double-tap dictation on: tap, then tap again within 0.35 s, and the second
    /// tap's recording stays on after its release. While it is locked a
    /// single press does nothing, and a double tap stops it (Danny's change,
    /// finding 9) as its second tap is let go: only then is that press known
    /// to be a tap, with no other key or click during it (Ruling T23-2).
    func testADoubleTapLocksUntilADoubleTapStopsIt() {
        var tracker = TapTracker(doubleTapEnabled: true)
        XCTAssertEqual(tracker.down(at: 0), .start)
        XCTAssertEqual(tracker.up(at: 0.1), .discardTap, "the first tap is no dictation")
        XCTAssertEqual(tracker.down(at: 0.3), .start, "the second tap records")
        XCTAssertEqual(tracker.up(at: 0.4), .none, "and its recording stays on")
        XCTAssertEqual(tracker.hold, .locked)
        XCTAssertEqual(tracker.down(at: 30), .none, "a press does nothing")
        XCTAssertEqual(tracker.up(at: 30.1), .none)
        XCTAssertEqual(tracker.hold, .locked)
        XCTAssertEqual(tracker.down(at: 30.3), .none, "a double tap's second press does nothing yet")
        XCTAssertEqual(tracker.up(at: 30.4), .stop, "its release stops it")
        XCTAssertEqual(tracker.hold, .none)
        XCTAssertEqual(tracker.down(at: 31), .start, "the press after that dictates as before")
        XCTAssertEqual(tracker.up(at: 32), .stop)
    }

    /// Double-tap dictation on, a single tap and then nothing: the tap's
    /// recording is thrown away, and nothing stays on.
    func testWithDoubleTapOnASingleTapIsDiscarded() {
        var tracker = TapTracker(doubleTapEnabled: true)
        XCTAssertEqual(tracker.down(at: 0), .start)
        XCTAssertEqual(tracker.up(at: 0.2), .discardTap)
        XCTAssertEqual(tracker.hold, .none)
        XCTAssertLessThan(TapTracker.tapMaximum, AudioRecorder.minimumDuration,
                          "a tap is too short to keep anyway: throwing it away loses nothing")
    }

    /// A tap is a press of at most `tapMaximum`. A second tap locks only when
    /// it goes down within `doubleTapWindow` of the first one's release and
    /// is itself a tap.
    func testTheTapAndDoubleTapLimits() {
        let window = TapTracker.doubleTapWindow, tap = TapTracker.tapMaximum
        var tracker = TapTracker(doubleTapEnabled: true)

        XCTAssertEqual(tracker.down(at: 0), .start)
        XCTAssertEqual(tracker.up(at: tap + 0.01), .stop, "held a little past a tap: a dictation")

        XCTAssertEqual(tracker.down(at: 10), .start)
        XCTAssertEqual(tracker.up(at: 10.1), .discardTap)
        XCTAssertEqual(tracker.down(at: 10.1 + window + 0.01), .start)
        XCTAssertEqual(tracker.up(at: 10.1 + window + 0.02), .discardTap, "a second tap a little too late is a first tap")
        XCTAssertEqual(tracker.hold, .none)

        XCTAssertEqual(tracker.down(at: 20), .start)
        XCTAssertEqual(tracker.up(at: 20.1), .discardTap)
        XCTAssertEqual(tracker.down(at: 20.2), .start)
        XCTAssertEqual(tracker.up(at: 21.2), .stop, "a tap and then a hold is a dictation")
        XCTAssertEqual(tracker.hold, .none, "and locks nothing")

        let firstUp = 30 + tap - 0.01, secondDown = firstUp + window - 0.01
        XCTAssertEqual(tracker.down(at: 30), .start)
        XCTAssertEqual(tracker.up(at: firstUp), .discardTap)
        XCTAssertEqual(tracker.down(at: secondDown), .start)
        XCTAssertEqual(tracker.up(at: secondDown + tap - 0.01), .none, "just inside both limits: it locks")
        XCTAssertEqual(tracker.hold, .locked)
    }

    /// Double-tap dictation switched off while a double-tap recording runs:
    /// it stays locked, a press still does nothing and a double tap still
    /// stops it. After that, taps are short recordings again.
    func testTurningDoubleTapOffWhileLockedStillStopsOnADoubleTap() {
        var tracker = TapTracker()
        lock(.globe, &tracker)
        tracker.doubleTapEnabled = false
        XCTAssertEqual(tracker.down(at: 200), .none)
        XCTAssertEqual(tracker.up(at: 200.1), .none)
        XCTAssertEqual(tracker.down(at: 200.3), .none)
        XCTAssertEqual(tracker.up(at: 200.4), .stop)
        XCTAssertEqual(tracker.down(at: 201), .start)
        XCTAssertEqual(tracker.up(at: 201.1), .stop, "double-tap dictation off: a short recording")
    }

    /// The tap reports Globe down again at every modifier change while it is
    /// held: a down while it is down, or an up while it is up, changes nothing.
    func testRepeatedReportsChangeNothing() {
        var tracker = TapTracker(doubleTapEnabled: true)
        XCTAssertEqual(tracker.up(at: 0), .none, "a release with no press")
        XCTAssertEqual(tracker.down(at: 1), .start)
        XCTAssertEqual(tracker.down(at: 1.5), .none)
        XCTAssertEqual(tracker.up(at: 2), .stop)
        XCTAssertEqual(tracker.up(at: 2.5), .none)
    }

    /// A double-tap recording the recorder ended by itself (five minutes, an
    /// input change, a failure) leaves no lock behind: the next press
    /// dictates, rather than counting toward a double tap that would stop a
    /// recording that is already over.
    func testAPressAfterTheDoubleTapRecordingEndedByItselfDictates() {
        for state in [DictationState.transcribing, .cleaning, .idle, .error("Microphone in use by another app")] {
            var tracker = TapTracker()
            lock(.rightOption, &tracker)
            XCTAssertEqual(press(.rightOption, down: true, at: 200, &tracker, doubleTap: true, state: state), .start, "\(state)")
            XCTAssertEqual(press(.rightOption, down: false, at: 201, &tracker, doubleTap: true), .stop, "\(state)")
        }
        var tracker = TapTracker()
        lock(.rightOption, &tracker)
        XCTAssertEqual(doubleTap(.rightOption, at: 200, &tracker), [.none, .none, .none, .stop],
                       "still recording: a press does nothing, and a double tap stops it")
    }

    // MARK: - Ending double-tap dictation (Danny's change, finding 9)

    /// While locked, a single tap does nothing: the recording goes on.
    func testASingleTapWhileLockedDoesNothing() {
        for choice in HotkeyChoice.allCases {
            var tracker = TapTracker()
            lock(choice, &tracker)
            XCTAssertEqual(press(choice, down: true, at: 200, &tracker, doubleTap: true), .none, "\(choice)")
            XCTAssertEqual(press(choice, down: false, at: 200.1, &tracker, doubleTap: true), .none, "\(choice)")
            XCTAssertEqual(tracker.hold, .locked, "\(choice): still locked")
        }
    }

    /// While locked, a long press does nothing either, and is no first tap:
    /// a quick tap just after its release is a first tap, so the recording
    /// stops only at the tap after that. Nor is a long press going down just
    /// after a tap the double tap's second: it is no tap, so it does nothing
    /// (finding 9: a long press also clears a pending first tap).
    func testALongPressWhileLockedDoesNothing() {
        for choice in HotkeyChoice.allCases {
            var tracker = TapTracker()
            lock(choice, &tracker)
            XCTAssertEqual(press(choice, down: true, at: 200, &tracker, doubleTap: true), .none, "\(choice)")
            XCTAssertEqual(press(choice, down: false, at: 201, &tracker, doubleTap: true), .none, "\(choice)")
            XCTAssertEqual(tracker.hold, .locked, "\(choice): still locked")
            XCTAssertEqual(doubleTap(choice, at: 201.1, &tracker), [.none, .none, .none, .stop],
                           "\(choice): the long press was no first tap")

            var afterATap = TapTracker()
            lock(choice, &afterATap)
            XCTAssertEqual(press(choice, down: true, at: 200, &afterATap, doubleTap: true), .none, "\(choice)")
            XCTAssertEqual(press(choice, down: false, at: 200.1, &afterATap, doubleTap: true), .none, "\(choice): a tap")
            XCTAssertEqual(press(choice, down: true, at: 200.3, &afterATap, doubleTap: true), .none,
                           "\(choice): a long press going down within the window")
            XCTAssertEqual(press(choice, down: false, at: 201.3, &afterATap, doubleTap: true), .none,
                           "\(choice): is no second tap")
            XCTAssertEqual(afterATap.hold, .locked, "\(choice): still locked")
            XCTAssertEqual(doubleTap(choice, at: 201.4, &afterATap), [.none, .none, .none, .stop],
                           "\(choice): a double tap after it stops it")
        }
    }

    /// While locked, a double tap stops the recording: a tap, then a second
    /// tap going down within `doubleTapWindow` of the first one's release.
    /// The stop comes as the second tap is let go, when it is known to be a
    /// tap (Ruling T23-2); its press does nothing. After it a quick tap is a
    /// first tap again: double-tap dictation on, its recording is thrown away.
    func testADoubleTapWhileLockedStopsAsItsSecondTapIsLetGo() {
        let window = TapTracker.doubleTapWindow
        for choice in HotkeyChoice.allCases {
            var tracker = TapTracker()
            lock(choice, &tracker)
            XCTAssertEqual(press(choice, down: true, at: 200, &tracker, doubleTap: true), .none, "\(choice)")
            XCTAssertEqual(press(choice, down: false, at: 200.1, &tracker, doubleTap: true), .none, "\(choice)")
            XCTAssertEqual(press(choice, down: true, at: 200.1 + window - 0.01, &tracker, doubleTap: true), .none,
                           "\(choice): the second press, just inside the window, does nothing yet")
            XCTAssertEqual(tracker.hold, .locked, "\(choice)")
            XCTAssertEqual(press(choice, down: false, at: 200.5, &tracker, doubleTap: true), .stop,
                           "\(choice): its release stops it")
            XCTAssertEqual(tracker.hold, .none, "\(choice)")
            XCTAssertEqual(press(choice, down: true, at: 200.6, &tracker, doubleTap: true), .start, "\(choice): a quick tap after it")
            XCTAssertEqual(press(choice, down: false, at: 200.7, &tracker, doubleTap: true), .discardTap,
                           "\(choice): is a first tap")
            XCTAssertEqual(tracker.hold, .none, "\(choice)")
        }
    }

    /// While locked, a second tap going down more than `doubleTapWindow`
    /// after the first one's release does not stop the recording. It is a
    /// first tap itself, so a quick tap after it does.
    func testASlowSecondTapWhileLockedDoesNotStop() {
        let window = TapTracker.doubleTapWindow
        for choice in HotkeyChoice.allCases {
            var tracker = TapTracker()
            lock(choice, &tracker)
            XCTAssertEqual(press(choice, down: true, at: 200, &tracker, doubleTap: true), .none, "\(choice)")
            XCTAssertEqual(press(choice, down: false, at: 200.1, &tracker, doubleTap: true), .none, "\(choice)")
            let slow = 200.1 + window + 0.01
            XCTAssertEqual(press(choice, down: true, at: slow, &tracker, doubleTap: true), .none, "\(choice): a slow second tap")
            XCTAssertEqual(press(choice, down: false, at: slow + 0.1, &tracker, doubleTap: true), .none, "\(choice)")
            XCTAssertEqual(tracker.hold, .locked, "\(choice): does not stop it")
            XCTAssertEqual(press(choice, down: true, at: slow + 0.3, &tracker, doubleTap: true), .none, "\(choice)")
            XCTAssertEqual(press(choice, down: false, at: slow + 0.4, &tracker, doubleTap: true), .stop,
                           "\(choice): it was a first tap")
        }
    }

    /// Double-tap dictation on, quick taps one after another: the first is thrown
    /// away and the second locks. The tap that locked is no first tap toward
    /// stopping, so the third does nothing and the fourth stops the
    /// recording as it is let go. A fifth is a first tap again.
    func testQuickTapsInARowLockThenStopAtTheFourth() {
        for choice in HotkeyChoice.allCases {
            var tracker = TapTracker()
            let taps = [(0.0, 0.1), (0.2, 0.3), (0.4, 0.5), (0.6, 0.7), (0.8, 0.9)].map { down, up in
                [press(choice, down: true, at: down, &tracker, doubleTap: true),
                 press(choice, down: false, at: up, &tracker, doubleTap: true)]
            }
            XCTAssertEqual(taps[0], [.start, .discardTap], "\(choice): the first tap is thrown away")
            XCTAssertEqual(taps[1], [.start, .none], "\(choice): the second tap locks")
            XCTAssertEqual(taps[2], [.none, .none], "\(choice): the third does nothing")
            XCTAssertEqual(taps[3], [.none, .stop], "\(choice): the fourth stops as it is let go")
            XCTAssertEqual(taps[4], [.start, .discardTap], "\(choice): a fifth is a first tap again")
        }
    }

    // MARK: - Chorded presses (Ruling T23-2)

    /// A press of the hotkey with another key going down during it is the
    /// hotkey used as a modifier, never a tap. While locked it does nothing:
    /// two quick shortcuts made with the hotkey, Right Command+Z twice say,
    /// are no double tap, and the recording goes on.
    func testChordedPressesWhileLockedAreNotTaps() {
        for choice in HotkeyChoice.allCases {
            var tracker = TapTracker()
            lock(choice, &tracker)
            XCTAssertEqual(chordedPress(choice, from: 200, to: 200.1, &tracker), [.none, .none], "\(choice): the first shortcut")
            XCTAssertEqual(chordedPress(choice, from: 200.3, to: 200.4, &tracker), [.none, .none],
                           "\(choice): the second, within the window")
            XCTAssertEqual(tracker.hold, .locked, "\(choice): still locked")
        }
    }

    /// A chorded press also clears a pending first tap. A plain tap, then a
    /// shortcut made with the hotkey going down within `doubleTapWindow` of
    /// it, is no double tap; nor is the shortcut a first tap. So a plain
    /// double tap going down at once after both, within the window of either
    /// release, still takes its two taps: it stops the recording as its
    /// second tap is let go.
    func testChordedPressClearsAPendingTap() {
        for choice in HotkeyChoice.allCases {
            var tracker = TapTracker()
            lock(choice, &tracker)
            XCTAssertEqual(press(choice, down: true, at: 200, &tracker, doubleTap: true), .none, "\(choice)")
            XCTAssertEqual(press(choice, down: false, at: 200.1, &tracker, doubleTap: true), .none, "\(choice): a plain tap")
            XCTAssertEqual(chordedPress(choice, from: 200.2, to: 200.25, &tracker), [.none, .none],
                           "\(choice): a shortcut within the window does not stop it")
            XCTAssertEqual(tracker.hold, .locked, "\(choice): still locked")
            XCTAssertEqual(doubleTap(choice, at: 200.3, &tracker), [.none, .none, .none, .stop],
                           "\(choice): a plain double tap stops it, at its second tap")
            XCTAssertEqual(tracker.hold, .none, "\(choice)")
        }
    }

    /// A click during the press counts as a key does: the press is no tap.
    /// While locked, two quick presses with a click during each are no
    /// double tap, and a plain tap followed within the window by a press
    /// with a click stops nothing either.
    func testAClickDuringAPressMakesItNoTap() {
        for choice in HotkeyChoice.allCases {
            var tracker = TapTracker()
            lock(choice, &tracker)
            XCTAssertEqual(chordedPress(choice, from: 200, to: 200.1, &tracker, click: true), [.none, .none], "\(choice)")
            XCTAssertEqual(chordedPress(choice, from: 200.3, to: 200.4, &tracker, click: true), [.none, .none],
                           "\(choice): no double tap")
            XCTAssertEqual(press(choice, down: true, at: 201, &tracker, doubleTap: true), .none, "\(choice)")
            XCTAssertEqual(press(choice, down: false, at: 201.1, &tracker, doubleTap: true), .none, "\(choice): a plain tap")
            XCTAssertEqual(chordedPress(choice, from: 201.2, to: 201.25, &tracker, click: true), [.none, .none],
                           "\(choice): a press with a click, within the window, does not stop it")
            XCTAssertEqual(tracker.hold, .locked, "\(choice): still locked")
            XCTAssertEqual(doubleTap(choice, at: 201.3, &tracker), [.none, .none, .none, .stop], "\(choice)")
        }
    }

    /// The app's own paste, tagged, can land while the hotkey is down for a
    /// double tap: an earlier dictation pastes the moment its text is ready.
    /// It is no key the user pressed, so the press is still a tap, and the
    /// double tap still stops the recording. A click tagged as the app's own
    /// is the same, though the app posts none.
    func testTheAppsOwnPasteDuringAPressLeavesItATap() {
        for choice in HotkeyChoice.allCases {
            for click in [false, true] {
                var tracker = TapTracker()
                lock(choice, &tracker)
                for (down, up, release) in [(200.0, 200.1, HotkeyAction.none), (200.3, 200.4, .stop)] {
                    XCTAssertEqual(press(choice, down: true, at: down, &tracker, doubleTap: true), .none, "\(choice)")
                    if click {
                        XCTAssertEqual(ModifierKeyStrategy.action(forMouseDownWithUserData: PasteEngine.eventTag, choice: choice,
                                                                  tracker: &tracker), .none, "\(choice): the app's own click")
                    } else {
                        XCTAssertEqual(ownPaste(v, &tracker, state: recording), [.none, .none, .none], "\(choice): the app's own paste")
                    }
                    XCTAssertEqual(press(choice, down: false, at: up, &tracker, doubleTap: true), release,
                                   "\(choice), click \(click): still a double tap")
                }
            }
        }
    }

    // MARK: - Timing

    /// A press is timed by its events' own timestamps, nanoseconds since
    /// startup on `systemUptime`'s clock, not by when the tap handles them.
    /// Right Option held 1.1 s, both events handled late at 500 s (the main
    /// thread stalled): with double-tap dictation on, still a hold, not a tap.
    func testALongPressWhoseEventsArriveLateIsStillAHold() throws {
        let handled: TimeInterval = 500
        let down = try XCTUnwrap(ModifierKeyStrategy.eventTime(stampedAt: 498_800_000_000, handledAt: handled))
        let up = try XCTUnwrap(ModifierKeyStrategy.eventTime(stampedAt: 499_900_000_000, handledAt: handled))
        XCTAssertEqual(down, 498.8, accuracy: 1e-9)
        XCTAssertEqual(up, 499.9, accuracy: 1e-9)

        var tracker = TapTracker()
        XCTAssertEqual(press(.rightOption, down: true, at: down, &tracker, doubleTap: true), .start)
        XCTAssertEqual(press(.rightOption, down: false, at: up, &tracker, doubleTap: true), .stop, "held 1.1 s: a dictation")

        var timedAsHandled = TapTracker()
        XCTAssertEqual(press(.rightOption, down: true, at: handled, &timedAsHandled, doubleTap: true), .start)
        XCTAssertEqual(press(.rightOption, down: false, at: handled, &timedAsHandled, doubleTap: true), .discardTap,
                       "what timing by the handling would make of it")
    }

    /// A stamp is trusted only when it reads as a moment the tap could have
    /// been holding the event: not unstamped (0), not after it was handled,
    /// and at most `eventTimeLimit` before. A stamp on another clock fails
    /// that, such as mach ticks read as nanoseconds (24 times too small on
    /// Apple Silicon); the tap then times the event by its handling.
    func testAnEventStampIsTrustedOnlyOnTheUptimeClock() {
        let handled: TimeInterval = 500
        func time(_ stamp: CGEventTimestamp) -> TimeInterval? {
            ModifierKeyStrategy.eventTime(stampedAt: stamp, handledAt: handled)
        }
        XCTAssertEqual(ModifierKeyStrategy.eventTimeLimit, 10)
        XCTAssertNil(time(0), "unstamped")
        XCTAssertEqual(time(500_000_000_000), 500, "handled at once")
        XCTAssertEqual(time(490_000_000_000), 490, "handled at the limit")
        XCTAssertNil(time(489_900_000_000), "older than the limit")
        XCTAssertNil(time(500_100_000_000), "after it was handled")
        XCTAssertNil(time(500_000_000_000 * 3 / 125), "mach ticks, read as nanoseconds")
    }

    // MARK: - Which key a modifier change is about

    /// Right Option is detected from `flagsChanged` with key code 61 and
    /// Right Command from 54. The left-hand keys, 58 and 55, set the same
    /// Option and Command flags, and do nothing.
    func testRightHandKeysAreDetectedAndLeftHandOnesDoNothing() {
        XCTAssertEqual([kVK_RightOption, kVK_RightCommand, kVK_Option, kVK_Command], [61, 54, 58, 55])
        let rightOption = flags(.maskAlternate, NX_DEVICERALTKEYMASK), leftOption = flags(.maskAlternate, NX_DEVICELALTKEYMASK)
        let rightCommand = flags(.maskCommand, NX_DEVICERCMDKEYMASK), leftCommand = flags(.maskCommand, NX_DEVICELCMDKEYMASK)

        XCTAssertEqual(HotkeyChoice.rightOption.isDown(flagsChangedKeyCode: 61, flags: rightOption), true)
        XCTAssertEqual(HotkeyChoice.rightOption.isDown(flagsChangedKeyCode: 61, flags: []), false)
        XCTAssertNil(HotkeyChoice.rightOption.isDown(flagsChangedKeyCode: 58, flags: leftOption))
        XCTAssertNil(HotkeyChoice.rightOption.isDown(flagsChangedKeyCode: 54, flags: rightCommand))
        XCTAssertEqual(HotkeyChoice.rightCommand.isDown(flagsChangedKeyCode: 54, flags: rightCommand), true)
        XCTAssertEqual(HotkeyChoice.rightCommand.isDown(flagsChangedKeyCode: 54, flags: []), false)
        XCTAssertNil(HotkeyChoice.rightCommand.isDown(flagsChangedKeyCode: 55, flags: leftCommand))
        XCTAssertNil(HotkeyChoice.rightCommand.isDown(flagsChangedKeyCode: 61, flags: rightOption))

        for (choice, right, left) in [(HotkeyChoice.rightOption, rightOption, leftOption), (.rightCommand, rightCommand, leftCommand)] {
            let rightCode: Int64 = choice == .rightOption ? 61 : 54, leftCode: Int64 = choice == .rightOption ? 58 : 55
            var tracker = TapTracker()
            for (time, flags) in [(0.0, left), (1.0, []), (2.0, left), (3.0, [])] as [(TimeInterval, CGEventFlags)] {
                XCTAssertEqual(ModifierKeyStrategy.action(forFlagsChanged: leftCode, flags: flags, at: time, choice: choice,
                                                          tracker: &tracker, state: .idle), .none, "\(choice): the left-hand key")
            }
            XCTAssertEqual(ModifierKeyStrategy.action(forFlagsChanged: rightCode, flags: right, at: 4, choice: choice,
                                                      tracker: &tracker, state: .idle), .start, "\(choice)")
            XCTAssertEqual(ModifierKeyStrategy.action(forFlagsChanged: rightCode, flags: [], at: 5, choice: choice,
                                                      tracker: &tracker, state: recording), .stop, "\(choice)")
        }
    }

    /// Letting go of Right Option while the left one stays down still ends
    /// the dictation: the right-hand key's own bit tells, not the Option flag.
    func testReleasingTheRightKeyWhileTheLeftOneIsDownEndsTheDictation() {
        let leftOnly = flags(.maskAlternate, NX_DEVICELALTKEYMASK)
        let both = CGEventFlags(rawValue: leftOnly.rawValue | UInt64(NX_DEVICERALTKEYMASK))
        var tracker = TapTracker()
        func change(_ keyCode: Int64, _ flags: CGEventFlags, at time: TimeInterval) -> HotkeyAction {
            ModifierKeyStrategy.action(forFlagsChanged: keyCode, flags: flags, at: time, choice: .rightOption,
                                       tracker: &tracker, state: recording)
        }
        XCTAssertEqual(change(58, leftOnly, at: 0), .none, "left Option down")
        XCTAssertEqual(change(61, both, at: 1), .start, "right Option down")
        XCTAssertEqual(change(61, leftOnly, at: 2), .stop, "right Option up, the left one still down")
        XCTAssertEqual(change(58, [], at: 3), .none, "left Option up")
    }

    /// Globe is read as before Task 23: from the Fn flag of every modifier
    /// change, whichever key changed.
    func testGlobeIsTheFnFlagOfEveryModifierChange() {
        XCTAssertEqual(HotkeyChoice.globe.isDown(flagsChangedKeyCode: Int64(kVK_Function), flags: .maskSecondaryFn), true)
        XCTAssertEqual(HotkeyChoice.globe.isDown(flagsChangedKeyCode: Int64(kVK_Shift), flags: [.maskSecondaryFn, .maskShift]), true)
        XCTAssertEqual(HotkeyChoice.globe.isDown(flagsChangedKeyCode: Int64(kVK_Function), flags: []), false)
        XCTAssertEqual(HotkeyChoice.globe.isDown(flagsChangedKeyCode: 61, flags: flags(.maskAlternate, NX_DEVICERALTKEYMASK)), false)
    }

    // MARK: - Escape while working

    /// Escape is swallowed, and cancels everything, while the app is
    /// recording, transcribing or cleaning up, whether the hotkey is up, held
    /// or locked by a double tap. In any other state it goes to the app in front
    /// untouched; with the hotkey held it still cancels that hold, as any
    /// key pressed with the hotkey does.
    func testEscapeConsumedOnlyWhileBusy() {
        for state in working {
            for hold in [TapTracker.Hold.none, .held, .locked] {
                XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: escape, hold: hold, state: state),
                               .cancelAllAndConsume, "\(state), \(hold)")
            }
        }
        for state in notWorking {
            XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: escape, hold: .none, state: state), .none, "\(state)")
            XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: escape, hold: .locked, state: state), .none, "\(state)")
            XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: escape, hold: .held, state: state), .cancelHoldAndPass, "\(state)")
        }
    }

    /// Holding Escape cancels once: its key repeats are swallowed while the
    /// app works, so they cannot go on to cancel what waits in line, and
    /// pass to the app otherwise.
    func testHoldingEscapeCancelsOnce() {
        for state in working {
            XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: escape, isRepeat: true, hold: .none, state: state), .consume, "\(state)")
        }
        for state in notWorking {
            XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: escape, isRepeat: true, hold: .none, state: state), .none, "\(state)")
        }
    }

    /// Only a plain Escape cancels. ⌘⎋, ⌃⎋, ⌥⎋ and ⌥⌘⎋ are other apps'
    /// shortcuts (⌘⎋ is the one Danny's Claude Code editor integration
    /// uses): while the app works they go to the app in front and cancel
    /// nothing, the hotkey up or locked by a double tap, and the lock carries on.
    /// Shift, Caps Lock and Fn do not count: ⇧⎋ still cancels.
    func testEscapeWithCommandControlOrOptionPassesWhileWorking() {
        let shortcuts: [CGEventFlags] = [.maskCommand, .maskControl, .maskAlternate, [.maskAlternate, .maskCommand]]
        for choice in HotkeyChoice.allCases {
            for flags in shortcuts {
                var locked = TapTracker()
                lock(choice, &locked)
                XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: escape, flags: flags, choice: choice, tracker: &locked,
                                                          state: recording), .none, "\(choice), locked, flags \(hex(flags))")
                XCTAssertEqual(locked.hold, .locked, "\(choice), flags \(hex(flags)): the lock carries on")
                for state in working {
                    XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: escape, flags: flags, choice: choice, hold: .none,
                                                              state: state), .none, "\(choice), up, \(state), flags \(hex(flags))")
                }
            }
            var locked = TapTracker()
            lock(choice, &locked)
            XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: escape, choice: choice, tracker: &locked, state: recording),
                           .cancelAllAndConsume, "\(choice): a plain Escape while locked cancels")
            XCTAssertEqual(locked.hold, .none, "\(choice)")
        }
        for flags in [CGEventFlags.maskShift, .maskAlphaShift, .maskSecondaryFn] {
            for state in working {
                XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: escape, flags: flags, hold: .none, state: state),
                               .cancelAllAndConsume, "\(state), flags \(hex(flags))")
            }
        }
    }

    /// While the hotkey is held, its own modifier is on every event: Escape
    /// with Right Command held for the hotkey is a plain Escape, and cancels
    /// everything. Another of the three makes it a shortcut, which cancels
    /// only the hold and goes through, as any key with the hotkey held does.
    /// Once a key has cancelled the hold, the hotkey still down is just a
    /// modifier: Right Command and Escape are then ⌘⎋, which goes through.
    func testEscapeWithTheHeldHotkeysOwnModifierStillCancels() {
        let own: [(HotkeyChoice, CGEventFlags)] = [
            (.globe, .maskSecondaryFn), (.rightOption, flags(.maskAlternate, NX_DEVICERALTKEYMASK)),
            (.rightCommand, flags(.maskCommand, NX_DEVICERCMDKEYMASK)),
        ]
        for (choice, flags) in own {
            var held = TapTracker()
            XCTAssertEqual(press(choice, down: true, at: 0, &held), .start)
            XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: escape, flags: flags, choice: choice, tracker: &held,
                                                      state: recording), .cancelAllAndConsume, "\(choice)")
            XCTAssertEqual(held.hold, .none, "\(choice)")

            var withControl = TapTracker()
            XCTAssertEqual(press(choice, down: true, at: 0, &withControl), .start)
            XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: escape, flags: flags.union(.maskControl), choice: choice,
                                                      tracker: &withControl, state: recording), .cancelHoldAndPass,
                           "\(choice): with Control as well")
        }
        var cancelled = TapTracker()
        XCTAssertEqual(press(.rightCommand, down: true, at: 0, &cancelled), .start)
        XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: Int64(kVK_RightArrow), choice: .rightCommand, tracker: &cancelled,
                                                  state: recording), .cancelHoldAndPass)
        XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: escape, flags: flags(.maskCommand, NX_DEVICERCMDKEYMASK),
                                                  choice: .rightCommand, tracker: &cancelled, state: .transcribing), .none,
                       "the hold already cancelled: ⌘⎋ goes through")
    }

    /// Escape while a dictation is held ends the hold too: the key's release
    /// then does nothing, and the next press dictates as usual.
    func testEscapeEndsTheHoldAndItsReleaseDoesNothing() {
        for choice in HotkeyChoice.allCases {
            var tracker = TapTracker()
            XCTAssertEqual(press(choice, down: true, at: 0, &tracker), .start, "\(choice)")
            XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: escape, tracker: &tracker, state: recording), .cancelAllAndConsume)
            XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: escape, tracker: &tracker, state: .idle), .none,
                           "\(choice): a second Escape goes to the app")
            XCTAssertEqual(press(choice, down: false, at: 1, &tracker), .none, "\(choice): the release does nothing")
            XCTAssertEqual(press(choice, down: true, at: 2, &tracker), .start, "\(choice): the next press dictates")
        }
    }

    // MARK: - Other keys

    /// Task 9's rule, for every choice: a key pressed while the hotkey is held
    /// cancels that hold's dictation (the hotkey used as a modifier) and goes
    /// through. The release then does nothing, and the next press dictates.
    func testAnotherKeyWhileHeldCancelsThatHoldForEveryChoice() {
        for choice in HotkeyChoice.allCases {
            for key in otherKeys {
                var tracker = TapTracker()
                XCTAssertEqual(press(choice, down: true, at: 0, &tracker), .start)
                XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: key, tracker: &tracker, state: recording),
                               .cancelHoldAndPass, "\(choice), key \(key)")
                XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: key, tracker: &tracker, state: .idle), .none,
                               "\(choice), key \(key): already cancelled")
                XCTAssertEqual(press(choice, down: false, at: 1, &tracker), .none, "\(choice): the release does nothing")
                XCTAssertEqual(press(choice, down: true, at: 2, &tracker), .start, "\(choice): the next press dictates")
            }
        }
    }

    /// Ruling T23-3: a click while a right-hand hotkey is held is a
    /// modifier-click (Right Command+click opens a link in a new tab, Right
    /// Option+click is many apps' own), so it cancels that hold's dictation
    /// with `cancelHold()`, as a key does. Globe+click is no shortcut, and
    /// holding Globe while clicking where the text should go is a plausible
    /// way to dictate: the click cancels nothing, and the release stops the
    /// dictation as usual. Either way the click goes through.
    func testAClickCancelsAHeldRightHandKeyButNotGlobe() {
        XCTAssertEqual(ModifierKeyStrategy.action(forMouseDownWithUserData: 0, choice: .globe, hold: .held), .none, "Globe")
        XCTAssertEqual(ModifierKeyStrategy.action(forMouseDownWithUserData: 0, choice: .rightCommand, hold: .held),
                       .cancelHoldAndPass, "Right Command")
        XCTAssertEqual(ModifierKeyStrategy.action(forMouseDownWithUserData: 0, choice: .rightOption, hold: .held),
                       .cancelHoldAndPass, "Right Option")
        XCTAssertFalse(KeyAction.cancelHoldAndPass.consumes, "the click goes through")

        for choice in [HotkeyChoice.rightOption, .rightCommand] {
            var held = TapTracker()
            XCTAssertEqual(press(choice, down: true, at: 0, &held), .start)
            XCTAssertEqual(ModifierKeyStrategy.action(forMouseDownWithUserData: 0, choice: choice, tracker: &held),
                           .cancelHoldAndPass, "\(choice)")
            XCTAssertEqual(held.hold, .none, "\(choice)")
            XCTAssertEqual(press(choice, down: false, at: 1, &held), .none, "\(choice): the release does nothing")
            XCTAssertEqual(press(choice, down: true, at: 2, &held), .start, "\(choice): the next press dictates")
        }

        var globe = TapTracker()
        XCTAssertEqual(press(.globe, down: true, at: 0, &globe), .start)
        XCTAssertEqual(ModifierKeyStrategy.action(forMouseDownWithUserData: 0, choice: .globe, tracker: &globe), .none, "Globe")
        XCTAssertEqual(globe.hold, .held, "Globe: still dictating")
        XCTAssertEqual(press(.globe, down: false, at: 3, &globe), .stop, "Globe: its release stops the dictation")
    }

    /// With Globe held a click cancels nothing, but the press is still no
    /// tap (Ruling T23-2). Let go quickly with double-tap dictation on, it is a
    /// dictation too short to keep, not a tap thrown away; and it is no tap
    /// toward a lock: after a plain tap it locks nothing, and that tap is no
    /// longer pending.
    func testAQuickPressOfGlobeWithAClickIsNoTap() {
        var tracker = TapTracker()
        XCTAssertEqual(press(.globe, down: true, at: 0, &tracker, doubleTap: true), .start)
        XCTAssertEqual(ModifierKeyStrategy.action(forMouseDownWithUserData: 0, choice: .globe, tracker: &tracker), .none)
        XCTAssertEqual(press(.globe, down: false, at: 0.1, &tracker, doubleTap: true), .stop, "a short dictation, not a tap")

        XCTAssertEqual(press(.globe, down: true, at: 10, &tracker, doubleTap: true), .start)
        XCTAssertEqual(press(.globe, down: false, at: 10.1, &tracker, doubleTap: true), .discardTap, "a plain tap")
        XCTAssertEqual(press(.globe, down: true, at: 10.2, &tracker, doubleTap: true), .start)
        XCTAssertEqual(ModifierKeyStrategy.action(forMouseDownWithUserData: 0, choice: .globe, tracker: &tracker), .none)
        XCTAssertEqual(press(.globe, down: false, at: 10.25, &tracker, doubleTap: true), .stop, "a press with a click: no lock")
        XCTAssertEqual(tracker.hold, .none)
        XCTAssertEqual(press(.globe, down: true, at: 10.3, &tracker, doubleTap: true), .start)
        XCTAssertEqual(press(.globe, down: false, at: 10.35, &tracker, doubleTap: true), .discardTap,
                       "a plain tap within the window of both is a first tap")
    }

    /// While a double tap has it locked the key is up, and a click cancels
    /// nothing, whatever the hotkey (unchanged by Ruling T23-3); nor does one
    /// with the hotkey up. A click the app tagged as its own changes
    /// nothing, even with a right-hand key held.
    func testAClickWhileLockedOrWithTheHotkeyUpCancelsNothing() {
        for choice in HotkeyChoice.allCases {
            XCTAssertEqual(ModifierKeyStrategy.action(forMouseDownWithUserData: 0, choice: choice, hold: .locked), .none,
                           "\(choice), locked")
            XCTAssertEqual(ModifierKeyStrategy.action(forMouseDownWithUserData: 0, choice: choice, hold: .none), .none, "\(choice), up")
            XCTAssertEqual(ModifierKeyStrategy.action(forMouseDownWithUserData: PasteEngine.eventTag, choice: choice, hold: .held),
                           .none, "\(choice), held, tagged")

            var locked = TapTracker()
            lock(choice, &locked)
            XCTAssertEqual(ModifierKeyStrategy.action(forMouseDownWithUserData: 0, choice: choice, tracker: &locked), .none,
                           "\(choice), locked")
            XCTAssertEqual(locked.hold, .locked, "\(choice): the lock carries on")

            var up = TapTracker()
            XCTAssertEqual(ModifierKeyStrategy.action(forMouseDownWithUserData: 0, choice: choice, tracker: &up), .none, "\(choice), up")

            var tagged = TapTracker()
            XCTAssertEqual(press(choice, down: true, at: 0, &tagged), .start)
            XCTAssertEqual(ModifierKeyStrategy.action(forMouseDownWithUserData: PasteEngine.eventTag, choice: choice, tracker: &tagged),
                           .none, "\(choice): tagged as the app's own")
            XCTAssertEqual(tagged.hold, .held, "\(choice)")
        }
    }

    /// The tap listens for a mouse button going down, whichever button, as
    /// well as modifier changes and key-downs; not for moves, drags, ups or
    /// scrolls, which cancel nothing.
    func testTheTapListensForMouseDowns() {
        let mask = ModifierKeyStrategy.eventsOfInterest
        for type in [CGEventType.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown] {
            XCTAssertNotEqual(mask & (1 << type.rawValue), 0, "\(type.rawValue) is listened for")
        }
        for type in [CGEventType.keyUp, .leftMouseUp, .rightMouseUp, .otherMouseUp, .mouseMoved, .leftMouseDragged, .scrollWheel] {
            XCTAssertEqual(mask & (1 << type.rawValue), 0, "\(type.rawValue) is not")
        }
    }

    func testKeysDoNothingWhileTheHotkeyIsUp() {
        for state in working + notWorking {
            for key in otherKeys {
                XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: key, hold: .none, state: state), .none, "\(state), key \(key)")
            }
        }
    }

    /// While a double tap has it locked the hotkey is up and Danny is free to do
    /// anything: other keys go through and cancel nothing. Escape still
    /// cancels everything and ends the lock, and the next press dictates.
    func testWhileLockedOtherKeysGoThroughAndEscapeCancels() {
        for choice in HotkeyChoice.allCases {
            var tracker = TapTracker()
            lock(choice, &tracker)
            for key in otherKeys {
                XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: key, tracker: &tracker, state: recording), .none, "\(choice), key \(key)")
            }
            XCTAssertEqual(tracker.hold, .locked, "\(choice)")
            XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: escape, tracker: &tracker, state: recording), .cancelAllAndConsume)
            XCTAssertEqual(tracker.hold, .none, "\(choice)")
            XCTAssertEqual(press(choice, down: true, at: 200, &tracker, state: .idle), .start, "\(choice): the next press dictates")
        }
    }

    // MARK: - The app's own paste

    /// The app's own Cmd+V (a dictation's paste, or Paste last's) is tagged
    /// with `PasteEngine.eventTag`, and goes through untouched whatever the
    /// hotkey, whether it is held, locked by a double tap or up, and whatever the
    /// app is doing: it never cancels, is never swallowed, and the hold or
    /// the lock carries on.
    func testTheAppsOwnPasteIsUntouchedForEveryChoiceLockedOrBusy() {
        for choice in HotkeyChoice.allCases {
            for state in working + notWorking {
                for key in [v, escape] + otherKeys {
                    let untouched: [KeyAction] = [.none, .none, .none]
                    var held = TapTracker()
                    XCTAssertEqual(press(choice, down: true, at: 0, &held), .start)
                    XCTAssertEqual(ownPaste(key, &held, state: state), untouched, "\(choice), held, \(state), key \(key)")
                    XCTAssertEqual(press(choice, down: false, at: 1, &held), .stop, "\(choice): the hold carries on to its release")

                    var locked = TapTracker()
                    lock(choice, &locked)
                    XCTAssertEqual(ownPaste(key, &locked, state: state), untouched, "\(choice), locked, \(state), key \(key)")
                    XCTAssertEqual(locked.hold, .locked, "\(choice), \(state), key \(key): the lock carries on")

                    var up = TapTracker()
                    XCTAssertEqual(ownPaste(key, &up, state: state), untouched, "\(choice), up, \(state), key \(key)")
                }
            }
        }
    }

    // MARK: - Paste last's shortcut

    /// Control-Option-V, with its shortcut on, pastes the last transcript and
    /// is swallowed, whatever the app is doing and while a double-tap recording runs;
    /// held down, it pastes once. Off, with another modifier, or another
    /// key, it goes to the app untouched.
    func testControlOptionVPastesLastWhenItsShortcutIsOn() {
        for state in [DictationState.idle] + working {
            for hold in [TapTracker.Hold.none, .locked] {
                XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: v, flags: controlOption, hold: hold, state: state,
                                                          pasteLastShortcut: true), .pasteLastAndConsume, "\(state), \(hold)")
                XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: v, flags: controlOption, isRepeat: true, hold: hold, state: state,
                                                          pasteLastShortcut: true), .consume, "\(state), \(hold): a key repeat")
            }
        }
        XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: v, flags: controlOption.union(.maskAlphaShift), hold: .none,
                                                  state: .idle, pasteLastShortcut: true), .pasteLastAndConsume, "Caps Lock on")
        XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: v, flags: controlOption, hold: .none, state: .idle,
                                                  pasteLastShortcut: false), .none, "off: the key goes to the app")
        let otherFlags: [CGEventFlags] = [[], .maskControl, .maskAlternate, .maskCommand,
                                          controlOption.union(.maskShift), controlOption.union(.maskCommand)]
        for flags in otherFlags {
            XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: v, flags: flags, hold: .none, state: .idle,
                                                      pasteLastShortcut: true), .none, "flags \(String(flags.rawValue, radix: 16))")
        }
        XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: Int64(kVK_ANSI_C), flags: controlOption, hold: .none, state: .idle,
                                                  pasteLastShortcut: true), .none, "Control-Option-C")
    }

    /// Ruling T23-1: the paste waits for the first modifier change with
    /// neither Control nor Option down. Letting go of one of them is not
    /// enough, and other modifiers still down do not matter. It goes once,
    /// and pressing V again before letting go still pastes once.
    func testPasteLastGoesWhenControlAndOptionAreLetGo() {
        var wait = PasteLastWait()
        XCTAssertFalse(wait.modifiersChanged(to: []), "nothing waits")

        let first = wait.request()
        XCTAssertFalse(wait.modifiersChanged(to: controlOption), "both still down")
        XCTAssertFalse(wait.modifiersChanged(to: .maskControl), "Option let go first, Control still down")
        XCTAssertFalse(wait.modifiersChanged(to: .maskAlternate), "Control let go first, Option still down")
        XCTAssertTrue(wait.modifiersChanged(to: []), "both let go: it goes now")
        XCTAssertFalse(wait.modifiersChanged(to: []), "once")
        XCTAssertFalse(wait.capReached(for: first), "and not again at the cap")

        _ = wait.request()
        XCTAssertTrue(wait.modifiersChanged(to: [.maskShift, .maskCommand, .maskAlphaShift, .maskSecondaryFn]),
                      "other modifiers do not hold it back")

        _ = wait.request()
        let again = wait.request()
        XCTAssertTrue(wait.modifiersChanged(to: []), "V pressed twice before letting go")
        XCTAssertFalse(wait.modifiersChanged(to: []), "still pastes once")
        XCTAssertFalse(wait.capReached(for: again))
    }

    /// The cap: a paste still waiting `PasteLastWait.cap` (about a second)
    /// after its request goes anyway, Control or Option still down. Only the
    /// request's own timer does that; a timer whose request already went, or
    /// was dropped with the tap, does nothing.
    func testPasteLastGoesAnywayAtTheCap() {
        XCTAssertEqual(PasteLastWait.cap, 1)
        var wait = PasteLastWait()
        let held = wait.request()
        XCTAssertFalse(wait.modifiersChanged(to: controlOption))
        XCTAssertTrue(wait.capReached(for: held), "still down at the cap: it goes")
        XCTAssertFalse(wait.modifiersChanged(to: []), "and not again when they are let go")
        XCTAssertFalse(wait.capReached(for: held))

        let early = wait.request()
        XCTAssertTrue(wait.modifiersChanged(to: []))
        let late = wait.request()
        XCTAssertFalse(wait.capReached(for: early), "the earlier request's timer")
        XCTAssertTrue(wait.capReached(for: late))

        let dropped = wait.request()
        wait.cancel()
        XCTAssertFalse(wait.capReached(for: dropped), "dropped with the tap")
        XCTAssertFalse(wait.modifiersChanged(to: []))
    }

    /// While the hotkey is held, Control-Option-V is the hotkey used as a
    /// modifier, like any other key: the hold is cancelled and the key goes
    /// through.
    func testControlOptionVWhileTheHotkeyIsHeldIsAnotherKey() {
        XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: v, flags: controlOption, hold: .held, state: recording,
                                                  pasteLastShortcut: true), .cancelHoldAndPass)
    }

    // MARK: - A tap that missed events (Task 9's carried item, finding 4)

    /// macOS turned the tap off for a while, or the health check rebuilt it:
    /// it may have missed the key's release, or a press. It catches up with
    /// the key as it is now, read from the live modifier flags, for every
    /// choice. A held dictation whose key is still down carries on, and its
    /// release stops it; one whose release was missed stops now, and a late
    /// release does nothing. A double-tap lock carries on either way, since a
    /// press while locked does nothing (finding 9); a press it missed the
    /// start of is no first tap, and a double tap still stops the lock. A
    /// missed press while nothing was under way starts nothing, and its
    /// release does nothing.
    func testATapThatMissedEventsFollowsTheKeyAsItIsNow() {
        for choice in HotkeyChoice.allCases {
            let down = liveFlags(choice)
            func catchUp(_ flags: CGEventFlags, _ tracker: inout TapTracker) -> HotkeyAction {
                ModifierKeyStrategy.action(forLiveFlags: flags, choice: choice, tracker: &tracker)
            }

            var stillDown = TapTracker()
            XCTAssertEqual(press(choice, down: true, at: 0, &stillDown), .start)
            XCTAssertEqual(catchUp(down, &stillDown), .none, "\(choice): held, still down: it carries on")
            XCTAssertEqual(stillDown.hold, .held, "\(choice)")
            XCTAssertEqual(press(choice, down: false, at: 5, &stillDown), .stop, "\(choice): and its release stops it")

            var released = TapTracker()
            XCTAssertEqual(press(choice, down: true, at: 0, &released), .start)
            XCTAssertEqual(catchUp([], &released), .stop, "\(choice): held, its release missed: it stops now")
            XCTAssertEqual(press(choice, down: false, at: 1, &released), .none, "\(choice): a late release")
            XCTAssertEqual(press(choice, down: true, at: 2, &released), .start, "\(choice): the next press dictates")

            var locked = TapTracker()
            lock(choice, &locked)
            XCTAssertEqual(catchUp([], &locked), .none, "\(choice): locked, the key up: it carries on")
            XCTAssertEqual(locked.hold, .locked, "\(choice)")
            XCTAssertEqual(doubleTap(choice, at: 200, &locked), [.none, .none, .none, .stop], "\(choice): a double tap stops it")

            var pressed = TapTracker()
            lock(choice, &pressed)
            XCTAssertEqual(catchUp(down, &pressed), .none, "\(choice): locked, the key down: a press does nothing")
            XCTAssertEqual(pressed.hold, .locked, "\(choice)")
            XCTAssertEqual(press(choice, down: false, at: 200.1, &pressed), .none, "\(choice): its release does nothing")
            XCTAssertEqual(doubleTap(choice, at: 200.2, &pressed), [.none, .none, .none, .stop],
                           "\(choice): that press was no first tap, and a double tap stops the lock")

            var missedPress = TapTracker()
            XCTAssertEqual(catchUp(down, &missedPress), .none, "\(choice): a missed press starts nothing")
            XCTAssertEqual(press(choice, down: true, at: 0.5, &missedPress), .none, "\(choice): nor does the key reported down again")
            XCTAssertEqual(press(choice, down: false, at: 1, &missedPress), .none, "\(choice): nor does its release stop anything")
            XCTAssertEqual(press(choice, down: true, at: 2, &missedPress), .start, "\(choice): the next press dictates")

            var cancelled = TapTracker()
            XCTAssertEqual(press(choice, down: true, at: 0, &cancelled), .start)
            XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: Int64(kVK_RightArrow), tracker: &cancelled, state: recording),
                           .cancelHoldAndPass)
            XCTAssertEqual(catchUp([], &cancelled), .none, "\(choice): a cancelled hold, its release missed")
            XCTAssertEqual(press(choice, down: true, at: 2, &cancelled), .start, "\(choice): the next press is not taken for the key still down")
        }
    }

    /// Only the chosen key's own state counts: the left-hand Option or
    /// Command key down, or the other right-hand key, is the chosen key up.
    func testTheLiveFlagsReadOnlyTheChosenKey() {
        let leftOption = flags(.maskAlternate, NX_DEVICELALTKEYMASK), leftCommand = flags(.maskCommand, NX_DEVICELCMDKEYMASK)
        for (choice, others) in [(HotkeyChoice.rightOption, [leftOption, liveFlags(.rightCommand), .maskSecondaryFn]),
                                 (.rightCommand, [leftCommand, liveFlags(.rightOption), .maskSecondaryFn]),
                                 (.globe, [leftOption, leftCommand, liveFlags(.rightOption)])] {
            XCTAssertTrue(choice.isDown(in:liveFlags(choice)), "\(choice)")
            for flags in others {
                XCTAssertFalse(choice.isDown(in:flags), "\(choice), flags \(hex(flags))")
                var held = TapTracker()
                XCTAssertEqual(press(choice, down: true, at: 0, &held), .start)
                XCTAssertEqual(ModifierKeyStrategy.action(forLiveFlags: flags, choice: choice, tracker: &held), .stop,
                               "\(choice), flags \(hex(flags)): its own key is up")
            }
        }
    }

    /// CGEventSource.h promises only "the current flags", and CGEventTypes.h
    /// names only the device-independent bits, so a right-hand key's own bit
    /// may be missing from the live flags. The same header's state of one
    /// key, by its code (61, 54), tells the right-hand key from the left
    /// without that bit, and adds it. Either reading is enough.
    func testTheLiveFlagsTakeARightHandKeyFromItsKeyStateToo() {
        func live(_ flagsState: CGEventFlags, keysDown: Set<CGKeyCode>) -> CGEventFlags {
            ModifierKeyStrategy.liveFlags(flagsState: flagsState, keyState: { keysDown.contains($0) })
        }
        let rightOption = CGKeyCode(kVK_RightOption), rightCommand = CGKeyCode(kVK_RightCommand)
        let leftOption = CGKeyCode(kVK_Option), leftCommand = CGKeyCode(kVK_Command)

        XCTAssertTrue(HotkeyChoice.rightOption.isDown(in:live(.maskAlternate, keysDown: [rightOption])), "no device bit")
        XCTAssertTrue(HotkeyChoice.rightCommand.isDown(in:live(.maskCommand, keysDown: [rightCommand])), "no device bit")
        XCTAssertFalse(HotkeyChoice.rightOption.isDown(in:live(.maskAlternate, keysDown: [leftOption])), "the left one")
        XCTAssertFalse(HotkeyChoice.rightCommand.isDown(in:live(.maskCommand, keysDown: [leftCommand])), "the left one")
        XCTAssertTrue(HotkeyChoice.rightOption.isDown(in:live(liveFlags(.rightOption), keysDown: [])), "the bit alone")
        XCTAssertTrue(HotkeyChoice.globe.isDown(in:live(.maskSecondaryFn, keysDown: [])), "Globe is its flag")
        XCTAssertEqual(live([.maskShift, .maskControl], keysDown: []), [.maskShift, .maskControl], "nothing else changes")
    }

    // MARK: - A tap taken down mid-press (carried in from Task 9)

    /// The tap is taken down for good while a dictation is held or locked:
    /// listening stops, or another hotkey's tap replaces it. No release will
    /// be seen, so the dictation stops as if the key had been let go: its
    /// recording is transcribed rather than left running until the next
    /// press or the 300 s stop. A release that does arrive afterwards does
    /// nothing more, and the next press dictates as usual.
    func testATapTakenDownStopsADictationUnderWay() {
        for choice in HotkeyChoice.allCases {
            var held = TapTracker()
            XCTAssertEqual(press(choice, down: true, at: 0, &held), .start)
            XCTAssertEqual(held.reset(), .stop, "\(choice), held")
            XCTAssertEqual(press(choice, down: false, at: 1, &held), .none, "\(choice): the late release")
            XCTAssertEqual(press(choice, down: true, at: 2, &held), .start, "\(choice): the next press")
            XCTAssertEqual(press(choice, down: false, at: 3, &held), .stop, "\(choice)")

            var locked = TapTracker()
            lock(choice, &locked)
            XCTAssertEqual(locked.reset(), .stop, "\(choice), locked")
            XCTAssertEqual(press(choice, down: true, at: 200, &locked), .start, "\(choice): the next press dictates")
        }
        var idle = TapTracker()
        XCTAssertEqual(idle.reset(), .none, "nothing under way")
        var cancelled = TapTracker()
        XCTAssertEqual(press(.globe, down: true, at: 0, &cancelled), .start)
        XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: Int64(kVK_RightArrow), tracker: &cancelled, state: recording),
                       .cancelHoldAndPass)
        XCTAssertEqual(cancelled.reset(), .none, "a hold a key already cancelled")
    }

    /// The wiring of the rule above: a strategy that stops mid-press
    /// (replaced for another hotkey, or listening stopped) tells its delegate
    /// the press ended, on the main queue, even when the strategy itself is
    /// gone by then. One with nothing under way tells nothing. These
    /// strategies never start, so no event tap is made.
    func testAStrategyStoppedMidPressEndsTheDictation() {
        let delegate = RecordingDelegate()
        var strategy: ModifierKeyStrategy? = ModifierKeyStrategy(choice: .rightOption)
        strategy?.delegate = delegate
        var held = TapTracker()
        XCTAssertEqual(press(.rightOption, down: true, at: 0, &held), .start)
        strategy?.tracker = held
        let idle = ModifierKeyStrategy(choice: .globe)
        idle.delegate = delegate

        strategy = nil
        idle.stop()
        let delivered = expectation(description: "the main queue has run what was queued before")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 2)

        XCTAssertEqual(delegate.calls, ["hotkeyDidEndPress"])
    }

    // MARK: - The choice and its preferences

    func testTheThreeChoicesAndTheirNames() {
        XCTAssertEqual(HotkeyChoice.allCases, [.globe, .rightOption, .rightCommand])
        XCTAssertEqual(HotkeyChoice.allCases.map(\.displayName), ["Globe", "Right Option", "Right Command"])
        XCTAssertEqual(HotkeyChoice.allCases.map(\.rawValue), ["globe", "rightOption", "rightCommand"],
                       "the preference is saved by these names")
    }

    /// Globe, double-tap dictation off and the Paste last shortcut off until
    /// Danny chooses otherwise; each choice is kept.
    func testHotkeyPreferencesDefaultAndAreKept() {
        let store = MemoryPreferenceStore()
        let preferences = PreferencesManager(defaults: store)
        XCTAssertEqual(preferences.hotkey, .globe)
        XCTAssertFalse(preferences.doubleTapEnabled)
        XCTAssertFalse(preferences.pasteLastHotkeyEnabled)

        preferences.hotkey = .rightCommand
        preferences.doubleTapEnabled = true
        preferences.pasteLastHotkeyEnabled = true

        let again = PreferencesManager(defaults: store)
        XCTAssertEqual(again.hotkey, .rightCommand)
        XCTAssertTrue(again.doubleTapEnabled)
        XCTAssertTrue(again.pasteLastHotkeyEnabled)
        // The names `defaults write com.danny.VoiceDictation` uses.
        XCTAssertEqual(store.string(forKey: "hotkey"), "rightCommand")
        XCTAssertEqual(store.object(forKey: "doubleTapEnabled") as? Bool, true)
        XCTAssertEqual(store.object(forKey: "pasteLastHotkeyEnabled") as? Bool, true)
    }

    /// Task 24 renamed the setting, its key included, with no migration: it
    /// was never in any window, so a value under the old key is not read.
    func testTheOldDoubleTapKeyIsNotRead() {
        let store = MemoryPreferenceStore()
        store.set(true, forKey: "handsFreeEnabled")
        XCTAssertFalse(PreferencesManager(defaults: store).doubleTapEnabled)
    }

    /// A saved key this version does not know (written by hand, or by a
    /// later version) reads as Globe rather than leaving no hotkey at all.
    func testAnUnknownSavedHotkeyReadsAsGlobe() {
        let store = MemoryPreferenceStore()
        store.set("leftShift", forKey: "hotkey")
        XCTAssertEqual(PreferencesManager(defaults: store).hotkey, .globe)
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

    /// Flags with one of IOLLEvent.h's device-dependent bits, as a real
    /// modifier change carries them.
    private func flags(_ flags: CGEventFlags, _ device: Int32) -> CGEventFlags {
        CGEventFlags(rawValue: flags.rawValue | UInt64(device))
    }

    /// Flags as a failure message shows them.
    private func hex(_ flags: CGEventFlags) -> String {
        String(flags.rawValue, radix: 16)
    }

    /// The live modifier flags with the chosen key down, as the tap reads
    /// them (`ModifierKeyStrategy.liveFlags`): Fn for Globe, the right-hand
    /// key's flag and its own device bit otherwise.
    private func liveFlags(_ choice: HotkeyChoice) -> CGEventFlags {
        switch choice {
        case .globe: return .maskSecondaryFn
        case .rightOption: return flags(.maskAlternate, NX_DEVICERALTKEYMASK)
        case .rightCommand: return flags(.maskCommand, NX_DEVICERCMDKEYMASK)
        }
    }

    /// The chosen key goes down or up at `time`, through the tap's rules, as
    /// a real `flagsChanged` event of that key carries it. Unless told, the
    /// app is recording, as it is after a press.
    private func press(_ choice: HotkeyChoice, down: Bool, at time: TimeInterval, _ tracker: inout TapTracker,
                       doubleTap: Bool = false, state: DictationState? = nil) -> HotkeyAction {
        let keyCode: Int64, keyFlags: CGEventFlags
        switch choice {
        case .globe: (keyCode, keyFlags) = (Int64(kVK_Function), down ? .maskSecondaryFn : [])
        case .rightOption: (keyCode, keyFlags) = (Int64(kVK_RightOption), down ? flags(.maskAlternate, NX_DEVICERALTKEYMASK) : [])
        case .rightCommand: (keyCode, keyFlags) = (Int64(kVK_RightCommand), down ? flags(.maskCommand, NX_DEVICERCMDKEYMASK) : [])
        }
        return ModifierKeyStrategy.action(forFlagsChanged: keyCode, flags: keyFlags, at: time, choice: choice,
                                          tracker: &tracker, doubleTap: doubleTap, state: state ?? recording)
    }

    /// A double tap of the chosen key with double-tap dictation on: the second tap's
    /// recording runs on, locked.
    private func lock(_ choice: HotkeyChoice, _ tracker: inout TapTracker,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(doubleTap(choice, at: 100, &tracker), [.start, .discardTap, .start, .none], "\(choice)",
                       file: file, line: line)
        XCTAssertEqual(tracker.hold, .locked, "\(choice)", file: file, line: line)
    }

    /// A quick double tap of the chosen key with double-tap dictation on, from `time`:
    /// down, up 0.1 s later, down again at 0.3 s and up at 0.4 s. Unlocked it
    /// locks; locked, it stops the recording.
    private func doubleTap(_ choice: HotkeyChoice, at time: TimeInterval, _ tracker: inout TapTracker) -> [HotkeyAction] {
        [press(choice, down: true, at: time, &tracker, doubleTap: true),
         press(choice, down: false, at: time + 0.1, &tracker, doubleTap: true),
         press(choice, down: true, at: time + 0.3, &tracker, doubleTap: true),
         press(choice, down: false, at: time + 0.4, &tracker, doubleTap: true)]
    }

    /// A press of the chosen key, double-tap dictation on, with another key going down
    /// during it: Z, carrying the key's own modifier as a real key-down does,
    /// as in Right Command+Z. Or, with `click`, a mouse button going down
    /// during it. While locked the key or the click goes through and cancels
    /// nothing, which this checks. Returns the hotkey's down and up.
    private func chordedPress(_ choice: HotkeyChoice, from down: TimeInterval, to up: TimeInterval,
                              _ tracker: inout TapTracker, click: Bool = false,
                              file: StaticString = #filePath, line: UInt = #line) -> [HotkeyAction] {
        let pressed = press(choice, down: true, at: down, &tracker, doubleTap: true)
        let other = click
            ? ModifierKeyStrategy.action(forMouseDownWithUserData: 0, choice: choice, tracker: &tracker)
            : ModifierKeyStrategy.action(forKeyDown: Int64(kVK_ANSI_Z), flags: liveFlags(choice), choice: choice,
                                         tracker: &tracker, state: recording)
        XCTAssertEqual(other, .none, "\(choice): the \(click ? "click" : "key") goes through", file: file, line: line)
        return [pressed, press(choice, down: false, at: up, &tracker, doubleTap: true)]
    }

    /// What the tap answers a key-down the app posted itself, tagged as
    /// `PasteEngine` tags its Cmd+V, with Paste last's shortcut on: with
    /// Command (as `PasteEngine` posts it), with Control-Option, and alone.
    private func ownPaste(_ key: Int64, _ tracker: inout TapTracker, state: DictationState) -> [KeyAction] {
        [CGEventFlags.maskCommand, controlOption, []].map { flags in
            ModifierKeyStrategy.action(forKeyDown: key, flags: flags, sourceUserData: PasteEngine.eventTag,
                                       tracker: &tracker, state: state, pasteLastShortcut: true)
        }
    }
}
