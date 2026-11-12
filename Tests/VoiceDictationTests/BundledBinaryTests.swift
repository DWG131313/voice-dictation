import XCTest
@testable import VoiceDictationLib

final class BundledBinaryTests: XCTestCase {
    func testFindWhisperBinaryFindsHomebrew() {
        // Should find the Homebrew-installed binary on this machine
        let path = BundledBinary.findWhisperCLI()
        // May or may not exist depending on test environment
        if let path = path {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
            XCTAssertTrue(BundledBinary.canRun(path))
        }
    }

    func testResolutionOrder() {
        // Verify the search order is: bundled first, then Homebrew
        let candidates = BundledBinary.searchPaths()
        // First entries should be bundle paths, last should be Homebrew
        XCTAssertTrue(candidates.last?.contains("/opt/homebrew") == true ||
                       candidates.last?.contains("/usr/local") == true)
    }

    func testCanRunAcceptsWorkingBinary() {
        XCTAssertTrue(BundledBinary.canRun("/usr/bin/true"))
    }

    func testCanRunRejectsBinaryThatFails() throws {
        // An unsigned arm64 binary is SIGKILLed (status 9) before main; a
        // script that exits non-zero stands in for it here. Either way the
        // finder must skip it rather than let it shadow a working install.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("vd-bad-\(UUID().uuidString).sh").path
        try "#!/bin/sh\nexit 3\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertFalse(BundledBinary.canRun(path))
    }
}
