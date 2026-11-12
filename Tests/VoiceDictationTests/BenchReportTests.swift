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
        XCTAssertTrue(summary.contains("| whisperKit/tiny.en | 0.90 | 0.300 | 2 |"), "median of 1.2 and 0.6")
        XCTAssertTrue(report.contains("\n## a.wav"))
        XCTAssertTrue(report.contains("\n## b.wav"))
        let bSection = report.components(separatedBy: "\n## b.wav")[1]
        XCTAssertFalse(bSection.contains("**"), "unchanged lines stay plain")
        XCTAssertTrue(report.contains("whisperCLI/base.en"))
        XCTAssertTrue(report.contains("set up **Tailscale** now"))
        XCTAssertTrue(report.contains("set up **tail scale** now"))
    }

    // MARK: - diffWords edge cases

    func testDiffEmptyAgainstText() {
        let (a, b) = BenchReport.diffWords("", "a b")
        XCTAssertEqual(a, "")
        XCTAssertEqual(b, "**a b**")
    }

    func testDiffFirstAndLastWord() {
        XCTAssertEqual(BenchReport.diffWords("X b c", "x b c").0, "**X** b c")
        XCTAssertEqual(BenchReport.diffWords("a b X", "a b x").1, "a b **x**")
    }

    func testDiffKeepsSeparateRunsSeparate() {
        let (a, b) = BenchReport.diffWords("a X b Y c", "a x b y c")
        XCTAssertEqual(a, "a **X** b **Y** c")
        XCTAssertEqual(b, "a **x** b **y** c")
    }

    func testDiffPureInsertionAndDeletion() {
        let (a, b) = BenchReport.diffWords("a c", "a b c")
        XCTAssertEqual(a, "a c")
        XCTAssertEqual(b, "a **b** c")
        let (c, d) = BenchReport.diffWords("a b c", "a c")
        XCTAssertEqual(c, "a **b** c")
        XCTAssertEqual(d, "a c")
    }

    func testDiffWithRepeatedWords() {
        let (a, b) = BenchReport.diffWords("go go go now", "go go now")
        XCTAssertEqual(a.replacingOccurrences(of: "**", with: "").split(separator: " ").count, 4)
        XCTAssertEqual(b, "go go now")
        XCTAssertEqual(a.components(separatedBy: "**").count - 1, 2, "exactly one word marked")
    }

    func testDiffMarkersAreBalanced() {
        let pairs = [("a X b Y c", "a x b y c"), ("", "a b"), ("a b", ""), ("a b c d", "d c b a"), ("same", "same")]
        for (x, y) in pairs {
            let (a, b) = BenchReport.diffWords(x, y)
            XCTAssertEqual((a.components(separatedBy: "**").count - 1) % 2, 0, a)
            XCTAssertEqual((b.components(separatedBy: "**").count - 1) % 2, 0, b)
        }
    }

    // MARK: - Report shape

    func testFailedRowAndMissingLoadTime() {
        let rows = [
            BenchReport.Row(clip: "a.wav", audioSeconds: 2, model: "m1", text: "hi", seconds: 1),
            BenchReport.Row(clip: "a.wav", audioSeconds: 2, model: "m2", text: "", seconds: 0, failure: "boom"),
        ]
        let report = BenchReport.markdown(rows: rows)
        XCTAssertTrue(report.contains("- m2: failed: boom"))
        XCTAssertTrue(report.contains("| m1 | n/a |"))
        XCTAssertTrue(report.contains("| m2 | 0.00 | 0.000 | 0 |"))
    }

    func testWordDifferingFromOnlyOneOtherModelIsBold() {
        func row(_ model: String, _ text: String) -> BenchReport.Row {
            BenchReport.Row(clip: "a.wav", audioSeconds: 1, model: model, text: text, seconds: 1)
        }
        let report = BenchReport.markdown(rows: [
            row("m1", "set up Tailscale"), row("m2", "set up Tailscale"), row("m3", "set up tail scale"),
        ])
        XCTAssertTrue(report.contains("- m1 (1.00 s): set up **Tailscale**"))
        XCTAssertTrue(report.contains("- m2 (1.00 s): set up **Tailscale**"))
        XCTAssertTrue(report.contains("- m3 (1.00 s): set up **tail scale**"))
    }
}
