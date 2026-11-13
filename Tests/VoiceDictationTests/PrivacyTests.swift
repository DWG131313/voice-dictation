import XCTest

/// Nothing leaves the Mac (Global Constraints). FoundationModels also offers
/// a model that runs in Apple's cloud; no source file may name it, not even
/// in a comment.
final class PrivacyTests: XCTestCase {
    func testNoCloudModelReferenced() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VoiceDictationTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // the package
            .appendingPathComponent("Sources", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20, "Sources/ was not found at \(sources.path)")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("PrivateCloudCompute"), "\(file.path) names the cloud model")
        }
    }
}
