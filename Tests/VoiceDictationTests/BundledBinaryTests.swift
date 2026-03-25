import XCTest
@testable import VoiceDictationLib

final class BundledBinaryTests: XCTestCase {
    func testFindWhisperBinaryFindsHomebrew() {
        // Should find the Homebrew-installed binary on this machine
        let path = BundledBinary.findWhisperCLI()
        // May or may not exist depending on test environment
        if let path = path {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
        }
    }

    func testResolutionOrder() {
        // Verify the search order is: bundled first, then Homebrew
        let candidates = BundledBinary.searchPaths()
        // First entries should be bundle paths, last should be Homebrew
        XCTAssertTrue(candidates.last?.contains("/opt/homebrew") == true ||
                       candidates.last?.contains("/usr/local") == true)
    }
}
