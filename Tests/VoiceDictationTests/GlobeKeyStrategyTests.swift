import Carbon.HIToolbox
import XCTest
@testable import VoiceDictationLib

/// Task 9's Globe key rules, as `ModifierKeyStrategy` keeps them for the
/// Globe choice: the Fn flag of each modifier change is Globe's, a key
/// pressed while it is held cancels that hold, and the app's own Cmd+V never
/// does. `HotkeyLogicTests` covers every choice and the Task 23 rules.
final class GlobeKeyStrategyTests: XCTestCase {
    private let otherKeys = [kVK_RightArrow, kVK_LeftArrow, kVK_ForwardDelete, kVK_Delete, kVK_ANSI_A, kVK_Space, kVK_Return]
    private let recording = DictationState.recording(since: Date())

    func testKeysDoNothingWhileGlobeIsNotHeld() {
        for code in otherKeys + [kVK_Escape] {
            XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: Int64(code), hold: .none, state: .idle), .none, "key \(code)")
        }
    }

    /// Escape while Globe is held for a recording: since Task 23 that is
    /// Escape while working, so it cancels with `cancel()`, which while
    /// recording cancels the recording only, and is swallowed.
    func testEscapeWhileHeldCancelsAndIsSwallowed() {
        XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: Int64(kVK_Escape), hold: .held, state: recording), .cancelAllAndConsume)
    }

    /// Globe as a modifier: Globe+Right Arrow is End, Globe+Delete deletes
    /// forward. The key cancels the dictation and still reaches the app.
    func testOtherKeysWhileHeldCancelAndGoThrough() {
        for code in otherKeys {
            XCTAssertEqual(ModifierKeyStrategy.action(forKeyDown: Int64(code), hold: .held, state: recording), .cancelHoldAndPass, "key \(code)")
        }
    }

    /// Step 5's hands-on check, at the level of the rules: Globe+Right Arrow
    /// starts one dictation and cancels it. Shift pressed and let go while
    /// Globe stays down (Globe+Shift+Right Arrow selects to the end) starts
    /// nothing more, and neither does letting go of Globe.
    func testGlobeAsAModifierNeverDictates() {
        var tracker = TapTracker()

        XCTAssertEqual(change(kVK_Function, [.maskSecondaryFn], &tracker), .start, "Globe down")
        XCTAssertEqual(change(kVK_Shift, [.maskSecondaryFn, .maskShift], &tracker), .none, "Shift down, Globe still down")
        XCTAssertEqual(key(kVK_RightArrow, &tracker), .cancelHoldAndPass)
        XCTAssertEqual(key(kVK_RightArrow, &tracker), .none, "the dictation is already cancelled")
        XCTAssertEqual(change(kVK_Shift, [.maskSecondaryFn], &tracker), .none, "Shift up, Globe still down")
        XCTAssertEqual(change(kVK_Function, [], &tracker), .none, "Globe up")

        XCTAssertEqual(change(kVK_Function, [.maskSecondaryFn], &tracker), .start, "the next press dictates again")
        XCTAssertEqual(change(kVK_Function, [], &tracker), .stop)
    }

    func testEscapeCancelsOnceAndTheNextPressDictates() {
        var tracker = TapTracker()

        XCTAssertEqual(change(kVK_Function, [.maskSecondaryFn], &tracker), .start)
        XCTAssertEqual(key(kVK_Escape, &tracker), .cancelAllAndConsume)
        XCTAssertEqual(key(kVK_Escape, &tracker, state: .idle), .none, "a second Escape goes to the app")
        XCTAssertEqual(change(kVK_Function, [], &tracker), .none)
        XCTAssertEqual(change(kVK_Function, [.maskSecondaryFn], &tracker), .start)
    }

    /// The app pastes an earlier dictation with its own Cmd+V as soon as the
    /// text is ready, which can be while Globe is held for the next one.
    /// `PasteEngine` tags that keystroke, and the tap lets it through without
    /// consulting the press. It never cancels, whichever key it is, and the
    /// hold carries on to its release.
    func testOwnPasteNeverCancels() {
        var tracker = TapTracker()
        XCTAssertEqual(change(kVK_Function, [.maskSecondaryFn], &tracker), .start, "Globe down for the next dictation")

        for code in [kVK_ANSI_V, kVK_Escape] + otherKeys {
            let action = ModifierKeyStrategy.action(forKeyDown: Int64(code), sourceUserData: PasteEngine.eventTag,
                                                    tracker: &tracker, state: recording)
            XCTAssertEqual(action, .none, "key \(code)")
        }

        XCTAssertEqual(tracker.hold, .held, "the next dictation is no longer held")
        XCTAssertEqual(change(kVK_Function, [], &tracker), .stop, "its release ends it as usual")
    }

    /// A key the app did not post still cancels: one the user pressed has no
    /// source data, and another app's tag is not ours.
    func testKeysFromOtherSourcesStillCancel() {
        for sourceUserData in [0, 1, PasteEngine.eventTag + 1] {
            var tracker = TapTracker()
            XCTAssertEqual(change(kVK_Function, [.maskSecondaryFn], &tracker), .start)

            let action = ModifierKeyStrategy.action(forKeyDown: Int64(kVK_ANSI_V), sourceUserData: sourceUserData,
                                                    tracker: &tracker, state: recording)

            XCTAssertEqual(action, .cancelHoldAndPass, "source \(sourceUserData)")
            XCTAssertEqual(tracker.hold, .none, "source \(sourceUserData)")
        }
    }

    /// A rebuilt tap forgets a press under way, and since Task 23 stops its
    /// dictation as if Globe had been let go (`HotkeyLogicTests` has the rest).
    func testResetStopsAPressUnderWayAndForgetsIt() {
        var tracker = TapTracker()
        XCTAssertEqual(change(kVK_Function, [.maskSecondaryFn], &tracker), .start)

        XCTAssertEqual(tracker.reset(), .stop)

        XCTAssertEqual(tracker.hold, .none)
        XCTAssertEqual(change(kVK_Function, [], &tracker), .none)
        XCTAssertEqual(change(kVK_Function, [.maskSecondaryFn], &tracker), .start)
    }

    // MARK: - Helpers

    /// A modifier change with these flags, as the Globe choice reads it.
    private func change(_ keyCode: Int, _ flags: CGEventFlags, _ tracker: inout TapTracker) -> HotkeyAction {
        ModifierKeyStrategy.action(forFlagsChanged: Int64(keyCode), flags: flags, at: ProcessInfo.processInfo.systemUptime,
                                   choice: .globe, tracker: &tracker, state: recording)
    }

    /// A key-down the user pressed, while the app records unless told.
    private func key(_ keyCode: Int, _ tracker: inout TapTracker, state: DictationState? = nil) -> KeyAction {
        ModifierKeyStrategy.action(forKeyDown: Int64(keyCode), tracker: &tracker, state: state ?? recording)
    }
}
