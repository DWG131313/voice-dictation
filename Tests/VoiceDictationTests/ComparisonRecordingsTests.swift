import XCTest
@testable import VoiceDictationLib

/// Ruling T9-1: while "Keep recordings for comparison" is on, every outcome
/// with a clip leaves `<ms stem>.wav` and `<ms stem>.txt` behind.
final class ComparisonRecordingsTests: XCTestCase {
    private let clip = AudioClip(samples: (0..<8_000).map { Float($0 % 100) / 200 })
    /// Exact in milliseconds, so the stem is predictable.
    private let date = Date(timeIntervalSince1970: 1_762_900_000.5)
    private let queue = DispatchQueue(label: "ComparisonRecordingsTests")
    private let preferences = PreferencesManager(defaults: MemoryPreferenceStore())
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vd-comparison-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testKeepsTheClipAndRawTextUnderTheMillisecondStem() throws {
        preferences.keepComparisonRecordings = true

        recordings().keep(outcome(rawText: "Hello there.", status: .pasted))
        queue.sync {}

        let stem = directory.appendingPathComponent("1762900000500")
        XCTAssertEqual(try String(contentsOf: stem.appendingPathExtension("txt"), encoding: .utf8), "Hello there.")
        XCTAssertEqual(try AudioClip(contentsOf: stem.appendingPathExtension("wav")).samples.count, clip.samples.count)
    }

    func testFailedOutcomeKeepsItsClipWithEmptyText() throws {
        preferences.keepComparisonRecordings = true

        recordings().keep(outcome(rawText: "", status: .failed))
        queue.sync {}

        let stem = directory.appendingPathComponent("1762900000500")
        XCTAssertEqual(try String(contentsOf: stem.appendingPathExtension("txt"), encoding: .utf8), "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stem.appendingPathExtension("wav").path))
    }

    /// The files are written off the calling thread, so keeping a recording
    /// never delays the next dictation.
    func testWritesOffTheCallingThread() {
        preferences.keepComparisonRecordings = true
        queue.suspend()

        recordings().keep(outcome(rawText: "Hello there.", status: .pasted))

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "wrote before returning")
        queue.resume()
        queue.sync {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("1762900000500.wav").path))
    }

    func testNothingIsWrittenWhenTheSettingIsOff() {
        recordings().keep(outcome(rawText: "Hello there.", status: .pasted))
        queue.sync {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func recordings() -> ComparisonRecordings {
        ComparisonRecordings(directory: directory, preferences: preferences, queue: queue)
    }

    private func outcome(rawText: String, status: DictationOutcome.Status) -> DictationOutcome {
        DictationOutcome(date: date, clip: clip, rawText: rawText, text: rawText, model: .appleSpeech,
                         transcribeSeconds: 0.2, appName: "Notes", status: status,
                         failure: status == .failed ? "Apple Speech language files are not installed" : nil)
    }
}
