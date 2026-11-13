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
        for handsFree in [false, true] {
            var tracker = TapTracker(handsFreeEnabled: handsFree)
            XCTAssertEqual(tracker.down(at: 10), .start, "hands-free \(handsFree)")
            XCTAssertEqual(tracker.hold, .held)
            XCTAssertEqual(tracker.up(at: 11), .stop, "hands-free \(handsFree)")
            XCTAssertEqual(tracker.hold, .none)
        }
    }

    /// Hands-free off, nothing changes: two quick taps are two recordings,
    /// each too short for the recorder's 0.5 s rule, which throws them away
    /// as it always has.
    func testHandsFreeOffTwoQuickTapsAreTwoShortRecordings() {
        var tracker = TapTracker(handsFreeEnabled: false)
        for (down, up) in [(0.0, 0.1), (0.2, 0.3)] {
            XCTAssertEqual(tracker.down(at: down), .start)
            XCTAssertEqual(tracker.up(at: up), .stop)
            XCTAssertEqual(AudioRecorder.verdict(duration: up - down, peak: 0.5), .tooShort)
        }
        XCTAssertEqual(tracker.hold, .none, "no lock with hands-free off")
    }

    // MARK: - Hands-free

    /// Hands-free on: tap, then tap again within 0.35 s, and the second
    /// tap's recording stays on after its release, until the next press.
    func testHandsFreeDoubleTapLocksUntilTheNextPress() {
        var tracker = TapTracker(handsFreeEnabled: true)
        XCTAssertEqual(tracker.down(at: 0), .start)
        XCTAssertEqual(tracker.up(at: 0.1), .discardTap, "the first tap is no dictation")
        XCTAssertEqual(tracker.down(at: 0.3), .start, "the second tap records")
        XCTAssertEqual(tracker.up(at: 0.4), .none, "and its recording stays on")
        XCTAssertEqual(tracker.hold, .locked)
        XCTAssertEqual(tracker.down(at: 30), .stop, "the next press stops it")
        XCTAssertEqual(tracker.up(at: 30.1), .none, "and its release does nothing")
        XCTAssertEqual(tracker.hold, .none)
        XCTAssertEqual(tracker.down(at: 31), .start, "the press after that dictates as before")
        XCTAssertEqual(tracker.up(at: 32), .stop)
    }

    /// Hands-free on, a single tap and then nothing: the tap's recording is
    /// thrown away, and nothing stays on.
    func testHandsFreeSingleTapIsDiscarded() {
        var tracker = TapTracker(handsFreeEnabled: true)
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
        var tracker = TapTracker(handsFreeEnabled: true)

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

    /// Hands-free switched off while a hands-free recording runs: the next
    /// press still stops it, and taps are short recordings again.
    func testTurningHandsFreeOffWhileLockedStillStopsOnTheNextPress() {
        var tracker = TapTracker()
        lock(.globe, &tracker)
        tracker.handsFreeEnabled = false
        XCTAssertEqual(tracker.down(at: 200), .stop)
        XCTAssertEqual(tracker.up(at: 200.1), .none)
        XCTAssertEqual(tracker.down(at: 201), .start)
        XCTAssertEqual(tracker.up(at: 201.1), .stop)
    }

    /// The tap reports Globe down again at every modifier change while it is
    /// held: a down while it is down, or an up while it is up, changes nothing.
    func testRepeatedReportsChangeNothing() {
        var tracker = TapTracker(handsFreeEnabled: true)
        XCTAssertEqual(tracker.up(at: 0), .none, "a release with no press")
        XCTAssertEqual(tracker.down(at: 1), .start)
        XCTAssertEqual(tracker.down(at: 1.5), .none)
        XCTAssertEqual(tracker.up(at: 2), .stop)
        XCTAssertEqual(tracker.up(at: 2.5), .none)
    }

    /// A hands-free recording the recorder ended by itself (five minutes, an
    /// input change, a failure) leaves no lock behind: the next press
    /// dictates, rather than stopping a recording that is already over.
    func testAPressAfterTheHandsFreeRecordingEndedByItselfDictates() {
        for state in [DictationState.transcribing, .cleaning, .idle, .error("Microphone in use by another app")] {
            var tracker = TapTracker()
            lock(.rightOption, &tracker)
            XCTAssertEqual(press(.rightOption, down: true, at: 200, &tracker, handsFree: true, state: state), .start, "\(state)")
            XCTAssertEqual(press(.rightOption, down: false, at: 201, &tracker, handsFree: true), .stop, "\(state)")
        }
        var tracker = TapTracker()
        lock(.rightOption, &tracker)
        XCTAssertEqual(press(.rightOption, down: true, at: 200, &tracker, handsFree: true), .stop,
                       "still recording: the press stops it")
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
    /// or locked hands-free. In any other state it goes to the app in front
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

    func testKeysDoNothingWhileTheHotkeyIsUp() {
        for state in working + notWorking {
            for key in otherKeys {
                XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: key, hold: .none, state: state), .none, "\(state), key \(key)")
            }
        }
    }

    /// While hands-free is locked the hotkey is up and Danny is free to do
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
    /// hotkey, whether it is held, locked hands-free or up, and whatever the
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
    /// is swallowed, whatever the app is doing and while hands-free records;
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

    /// While the hotkey is held, Control-Option-V is the hotkey used as a
    /// modifier, like any other key: the hold is cancelled and the key goes
    /// through.
    func testControlOptionVWhileTheHotkeyIsHeldIsAnotherKey() {
        XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: v, flags: controlOption, hold: .held, state: recording,
                                                  pasteLastShortcut: true), .cancelHoldAndPass)
    }

    // MARK: - A tap rebuilt mid-press (carried in from Task 9)

    /// The health check may rebuild the tap while a dictation is held or
    /// locked, and the new tap may never see the release. The rebuild stops
    /// that dictation as if the key had been let go, so its recording is
    /// transcribed rather than left running until the next press or the
    /// 300 s stop. A release that does arrive afterwards does nothing more,
    /// and the next press dictates as usual.
    func testARebuiltTapStopsADictationUnderWay() {
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

    /// The wiring of the rule above: a strategy that stops mid-press (its tap
    /// rebuilt by the health check, or replaced for another hotkey) tells
    /// its delegate the press ended, on the main queue, even when the
    /// strategy itself is gone by then. One with nothing under way tells
    /// nothing. These strategies never start, so no event tap is made.
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

    /// Globe, hands-free off and the Paste last shortcut off until Danny
    /// chooses otherwise; each choice is kept.
    func testHotkeyPreferencesDefaultAndAreKept() {
        let store = MemoryPreferenceStore()
        let preferences = PreferencesManager(defaults: store)
        XCTAssertEqual(preferences.hotkey, .globe)
        XCTAssertFalse(preferences.handsFreeEnabled)
        XCTAssertFalse(preferences.pasteLastHotkeyEnabled)

        preferences.hotkey = .rightCommand
        preferences.handsFreeEnabled = true
        preferences.pasteLastHotkeyEnabled = true

        let again = PreferencesManager(defaults: store)
        XCTAssertEqual(again.hotkey, .rightCommand)
        XCTAssertTrue(again.handsFreeEnabled)
        XCTAssertTrue(again.pasteLastHotkeyEnabled)
        // The names `defaults write com.danny.VoiceDictation` uses.
        XCTAssertEqual(store.string(forKey: "hotkey"), "rightCommand")
        XCTAssertEqual(store.object(forKey: "handsFreeEnabled") as? Bool, true)
        XCTAssertEqual(store.object(forKey: "pasteLastHotkeyEnabled") as? Bool, true)
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

    /// The chosen key goes down or up at `time`, through the tap's rules, as
    /// a real `flagsChanged` event of that key carries it. Unless told, the
    /// app is recording, as it is after a press.
    private func press(_ choice: HotkeyChoice, down: Bool, at time: TimeInterval, _ tracker: inout TapTracker,
                       handsFree: Bool = false, state: DictationState? = nil) -> HotkeyAction {
        let keyCode: Int64, keyFlags: CGEventFlags
        switch choice {
        case .globe: (keyCode, keyFlags) = (Int64(kVK_Function), down ? .maskSecondaryFn : [])
        case .rightOption: (keyCode, keyFlags) = (Int64(kVK_RightOption), down ? flags(.maskAlternate, NX_DEVICERALTKEYMASK) : [])
        case .rightCommand: (keyCode, keyFlags) = (Int64(kVK_RightCommand), down ? flags(.maskCommand, NX_DEVICERCMDKEYMASK) : [])
        }
        return ModifierKeyStrategy.action(forFlagsChanged: keyCode, flags: keyFlags, at: time, choice: choice,
                                          tracker: &tracker, handsFree: handsFree, state: state ?? recording)
    }

    /// A double tap of the chosen key with hands-free on: the second tap's
    /// recording runs on, locked.
    private func lock(_ choice: HotkeyChoice, _ tracker: inout TapTracker,
                      file: StaticString = #filePath, line: UInt = #line) {
        let actions = [
            press(choice, down: true, at: 100, &tracker, handsFree: true),
            press(choice, down: false, at: 100.1, &tracker, handsFree: true),
            press(choice, down: true, at: 100.3, &tracker, handsFree: true),
            press(choice, down: false, at: 100.4, &tracker, handsFree: true),
        ]
        XCTAssertEqual(actions, [.start, .discardTap, .start, .none], "\(choice)", file: file, line: line)
        XCTAssertEqual(tracker.hold, .locked, "\(choice)", file: file, line: line)
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
