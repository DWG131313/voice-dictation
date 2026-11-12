import XCTest
@testable import VoiceDictationLib

final class LogTests: XCTestCase {
    /// Ruling T8-3: test runs print their lines but keep them out of
    /// `~/Library/Logs/VoiceDictation.log`, the log Danny reads.
    func testTestRunsLeaveTheLogFileAlone() {
        let line = "[TEST] LogTests \(UUID().uuidString)"

        Log.info(line)
        Log.flush()

        let rotated = Log.fileURL.deletingPathExtension().appendingPathExtension("log.old")
        for file in [Log.fileURL, rotated] {
            let contents = (try? Data(contentsOf: file)) ?? Data()
            XCTAssertNil(contents.range(of: Data(line.utf8)), "the test wrote to \(file.path)")
        }
    }
}
