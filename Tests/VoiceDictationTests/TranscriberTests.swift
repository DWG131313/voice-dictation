import XCTest
@testable import VoiceDictationLib

final class TranscriberTests: XCTestCase {
    func testParseWhisperOutput() {
        let output = """
        [00:00:00.000 --> 00:00:03.000]   Hello, this is a test.
        [00:00:03.000 --> 00:00:05.000]   Second sentence.
        """
        let result = Transcriber.parseOutput(output)
        XCTAssertEqual(result, "Hello, this is a test. Second sentence.")
    }

    func testParseWhisperOutputNoTimestamps() {
        let output = "  Hello, this is a test.\n  Second sentence.\n"
        let result = Transcriber.parseOutput(output)
        XCTAssertEqual(result, "Hello, this is a test. Second sentence.")
    }

    func testParseEmptyOutput() {
        let result = Transcriber.parseOutput("")
        XCTAssertEqual(result, "")
    }

    func testParseWhisperOutputWithBlankAudio() {
        let output = "[BLANK_AUDIO]\n"
        let result = Transcriber.parseOutput(output)
        XCTAssertEqual(result, "")
    }

    func testFindBinaryPath() {
        // This test verifies the resolution logic doesn't crash
        // Whether it finds a binary depends on the test environment
        _ = Transcriber.findBinaryPath()
    }

    func testTimeoutCalculation() {
        XCTAssertEqual(Transcriber.calculateTimeout(recordingDuration: 1.0), 10.0)
        XCTAssertEqual(Transcriber.calculateTimeout(recordingDuration: 5.0), 15.0)
        XCTAssertEqual(Transcriber.calculateTimeout(recordingDuration: 2.0), 10.0)
    }
}
