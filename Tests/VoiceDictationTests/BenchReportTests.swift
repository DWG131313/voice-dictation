import XCTest
@testable import VoiceDictationLib

final class BenchReportTests: XCTestCase {
    func testMedian() {
        XCTAssertEqual(BenchReport.median([3, 1, 2]), 2)
        XCTAssertEqual(BenchReport.median([4, 1, 3, 2]), 2.5)
        XCTAssertEqual(BenchReport.median([]), 0)
    }

    func testDiffMarksOnlyChangedWords() {
        let (a, b) = BenchReport.diffWords("set up Tailscale now", "set up tail scale now")
        XCTAssertEqual(a, "set up **Tailscale** now")
        XCTAssertEqual(b, "set up **tail scale** now")
    }

    func testDiffOfEqualTextMarksNothing() {
        let (a, b) = BenchReport.diffWords("all the same", "all the same")
        XCTAssertEqual(a, "all the same")
        XCTAssertEqual(b, "all the same")
    }

    func testReportHasOneRowPerModel() {
        let rows = [
            BenchReport.Row(clip: "a.wav", audioSeconds: 4, model: "appleSpeech/en-US", text: "set up Tailscale now", seconds: 0.4),
            BenchReport.Row(clip: "a.wav", audioSeconds: 4, model: "whisperKit/tiny.en", text: "set up tail scale now", seconds: 1.2),
            BenchReport.Row(clip: "b.wav", audioSeconds: 2, model: "appleSpeech/en-US", text: "hello", seconds: 0.2),
            BenchReport.Row(clip: "b.wav", audioSeconds: 2, model: "whisperKit/tiny.en", text: "hello", seconds: 0.6),
        ]
        let report = BenchReport.markdown(
            rows: rows, loadSeconds: ["appleSpeech/en-US": 0.5],
            skipped: ["whisperCLI/base.en": "model not downloaded"]
        )
        let summary = report.components(separatedBy: "\n## ")[0]
        XCTAssertEqual(summary.components(separatedBy: "\n").filter { $0.hasPrefix("| appleSpeech/en-US") }.count, 2, "summary + load tables")
        XCTAssertEqual(summary.components(separatedBy: "\n").filter { $0.hasPrefix("| whisperKit/tiny.en") }.count, 2)
        XCTAssertTrue(summary.contains("| appleSpeech/en-US | 0.30 | 0.100 | 2 |"))
        XCTAssertTrue(report.contains("whisperCLI/base.en"))
        XCTAssertTrue(report.contains("set up **Tailscale** now"))
        XCTAssertTrue(report.contains("set up **tail scale** now"))
    }
}
