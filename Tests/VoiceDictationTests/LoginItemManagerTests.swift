import XCTest
@testable import VoiceDictationLib

final class LoginItemManagerTests: XCTestCase {
    func testRecognizesInstalledAppBundlePath() {
        let path = "/Applications/VoiceDictation.app/Contents/MacOS/VoiceDictation"
        XCTAssertTrue(LoginItemManager.isRunningFromAppBundle(executablePath: path))
    }

    func testDevBuildPathIsNotABundle() {
        let path = "/Users/danny/CodingProjects/Voice Dictation/.build/arm64-apple-macosx/debug/VoiceDictation"
        XCTAssertFalse(
            LoginItemManager.isRunningFromAppBundle(executablePath: path),
            "The .build dev binary must never be treated as an installable bundle — that is the path that accumulated stale login items"
        )
    }

    func testXCTestRunnerPathIsNotABundle() {
        // .xctest bundles share the Contents/MacOS layout but are not .app —
        // registration must not fire while running tests.
        let path = "/Users/danny/.build/debug/VoiceDictationPackageTests.xctest/Contents/MacOS/VoiceDictationPackageTests"
        XCTAssertFalse(LoginItemManager.isRunningFromAppBundle(executablePath: path))
    }

    func testEmptyPathIsNotABundle() {
        XCTAssertFalse(LoginItemManager.isRunningFromAppBundle(executablePath: ""))
    }
}
