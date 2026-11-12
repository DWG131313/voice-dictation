import Carbon.HIToolbox
import XCTest
@testable import VoiceDictationLib

final class GlobeKeyStrategyTests: XCTestCase {
    private let otherKeys = [kVK_RightArrow, kVK_LeftArrow, kVK_ForwardDelete, kVK_Delete, kVK_ANSI_A, kVK_Space, kVK_Return]

    func testKeysDoNothingWhileGlobeIsNotHeld() {
        for code in otherKeys + [kVK_Escape] {
            XCTAssertEqual(GlobeKeyStrategy.action(forKeyDown: Int64(code), whilePressed: false), .none, "key \(code)")
        }
    }

    func testEscapeWhileHeldCancelsAndIsSwallowed() {
        XCTAssertEqual(GlobeKeyStrategy.action(forKeyDown: Int64(kVK_Escape), whilePressed: true), .cancelAndConsume)
    }

    /// Globe as a modifier: Globe+Right Arrow is End, Globe+Delete deletes
    /// forward. The key cancels the dictation and still reaches the app.
    func testOtherKeysWhileHeldCancelAndGoThrough() {
        for code in otherKeys {
            XCTAssertEqual(GlobeKeyStrategy.action(forKeyDown: Int64(code), whilePressed: true), .cancelAndPass, "key \(code)")
        }
    }

    /// Step 5's hands-on check, at the level of the rules: Globe+Right Arrow
    /// starts one dictation and cancels it. Shift pressed and let go while
    /// Globe stays down (Globe+Shift+Right Arrow selects to the end) starts
    /// nothing more, and neither does letting go of Globe.
    func testGlobeAsAModifierNeverDictates() {
        var presses = GlobeKeyPresses()

        XCTAssertEqual(presses.globeChanged(isDown: true), .start, "Globe down")
        XCTAssertEqual(presses.globeChanged(isDown: true), .none, "Shift down, Globe still down")
        XCTAssertEqual(presses.keyDown(Int64(kVK_RightArrow)), .cancelAndPass)
        XCTAssertEqual(presses.keyDown(Int64(kVK_RightArrow)), .none, "the dictation is already cancelled")
        XCTAssertEqual(presses.globeChanged(isDown: true), .none, "Shift up, Globe still down")
        XCTAssertEqual(presses.globeChanged(isDown: false), .none, "Globe up")

        XCTAssertEqual(presses.globeChanged(isDown: true), .start, "the next press dictates again")
        XCTAssertEqual(presses.globeChanged(isDown: false), .end)
    }

    func testEscapeCancelsOnceAndTheNextPressDictates() {
        var presses = GlobeKeyPresses()

        XCTAssertEqual(presses.globeChanged(isDown: true), .start)
        XCTAssertEqual(presses.keyDown(Int64(kVK_Escape)), .cancelAndConsume)
        XCTAssertEqual(presses.keyDown(Int64(kVK_Escape)), .none, "a second Escape goes to the app")
        XCTAssertEqual(presses.globeChanged(isDown: false), .none)
        XCTAssertEqual(presses.globeChanged(isDown: true), .start)
    }

    func testResetForgetsAPressUnderWay() {
        var presses = GlobeKeyPresses()
        XCTAssertEqual(presses.globeChanged(isDown: true), .start)

        presses.reset()

        XCTAssertFalse(presses.isPressed)
        XCTAssertEqual(presses.globeChanged(isDown: false), .none)
        XCTAssertEqual(presses.globeChanged(isDown: true), .start)
    }
}
