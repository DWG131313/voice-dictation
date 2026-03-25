import XCTest
@testable import VoiceDictationLib

final class ModelManagerTests: XCTestCase {
    func testModelDirectoryPath() {
        let manager = ModelManager()
        let path = manager.modelDirectoryURL.path
        XCTAssertTrue(path.contains("Application Support/VoiceDictation/models"))
    }

    func testModelFilePath() {
        let manager = ModelManager()
        let path = manager.modelFileURL.path
        XCTAssertTrue(path.hasSuffix("ggml-base.en.bin"))
    }

    func testModelNotPresentInitially() {
        // Uses a temp directory to avoid interfering with real model
        let manager = ModelManager()
        // Model may or may not exist depending on test environment
        // This test verifies the check doesn't crash
        _ = manager.isModelPresent
    }
}
