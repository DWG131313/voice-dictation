import XCTest
@testable import VoiceDictationLib

final class OutputFilterTests: XCTestCase {
    func testParseWhisperOutput() {
        let output = """
        [00:00:00.000 --> 00:00:03.000]   Hello, this is a test.
        [00:00:03.000 --> 00:00:05.000]   Second sentence.
        """
        let result = OutputFilter.clean(output)
        XCTAssertEqual(result, "Hello, this is a test. Second sentence.")
    }

    func testParseWhisperOutputNoTimestamps() {
        let output = "  Hello, this is a test.\n  Second sentence.\n"
        let result = OutputFilter.clean(output)
        XCTAssertEqual(result, "Hello, this is a test. Second sentence.")
    }

    func testParseEmptyOutput() {
        let result = OutputFilter.clean("")
        XCTAssertEqual(result, "")
    }

    func testParseWhisperOutputWithBlankAudio() {
        let output = "[BLANK_AUDIO]\n"
        let result = OutputFilter.clean(output)
        XCTAssertEqual(result, "")
    }

    func testParseDropsNonSpeechTokenLines() {
        let output = "[Music]\n(silence)\n*whoosh*\n Real words here.\n[inaudible]\n"
        XCTAssertEqual(OutputFilter.clean(output), "Real words here.")
    }

    func testParseKeepsBracketsInsideSpeech() {
        // Only a leading timestamp is stripped — brackets the user actually
        // dictated (or whisper placed mid-sentence) must survive intact.
        let output = "[00:00:00.000 --> 00:00:02.000]  Open bracket [x] close bracket."
        XCTAssertEqual(OutputFilter.clean(output), "Open bracket [x] close bracket.")

        let noStamp = "Array index [0] is first."
        XCTAssertEqual(OutputFilter.clean(noStamp), "Array index [0] is first.")
    }

    func testParseDropsSilenceHallucinations() {
        XCTAssertEqual(OutputFilter.clean("\n you"), "")
        XCTAssertEqual(OutputFilter.clean(" Thank you."), "")
        XCTAssertEqual(OutputFilter.clean(" Thanks for watching!"), "")
        // A real sentence that merely contains the phrase is untouched.
        XCTAssertEqual(OutputFilter.clean(" Thank you for the help today."), "Thank you for the help today.")
    }

    func testHallucinationAppliesToAnyEngine() {
        XCTAssertEqual(OutputFilter.clean(" Thank you. "), "")
    }

    func testBlankAudioThenAHallucinationCleansToNothing() {
        XCTAssertEqual(OutputFilter.clean("[BLANK_AUDIO]\n Thank you."), "")
    }
}
