import XCTest
@testable import VoiceDictationLib

/// `vd-bench`'s arguments and clips (Task 24): `--from-archive` reads the
/// app's kept recordings, so D1 no longer needs the comparison switch;
/// without it the tool still reads the comparison folder's WAVs.
final class BenchOptionsTests: XCTestCase {
    private let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support/VoiceDictation", isDirectory: true)
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vd-bench-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Arguments

    /// Without the flag, as before: the comparison folder's WAVs, and the
    /// report in `docs/engine-comparison.md`.
    func testWithoutTheFlagItReadsTheComparisonFolder() throws {
        let options = try BenchOptions.parse([], support: support)
        XCTAssertEqual(options.source, .wavs(support.appendingPathComponent("comparison", isDirectory: true)))
        XCTAssertEqual(options.outputPath, "docs/engine-comparison.md")
    }

    /// `--from-archive` reads the kept recordings in `audio/`, wherever it
    /// stands among the arguments, and `--output` still names the report.
    func testFromArchiveReadsTheKeptRecordings() throws {
        let archive = BenchOptions.Source.archive(support.appendingPathComponent("audio", isDirectory: true))
        XCTAssertEqual(try BenchOptions.parse(["--from-archive"], support: support).source, archive)

        for arguments in [["--from-archive", "--output", "report.md"], ["--output", "report.md", "--from-archive"]] {
            let options = try BenchOptions.parse(arguments, support: support)
            XCTAssertEqual(options.source, archive, "\(arguments)")
            XCTAssertEqual(options.outputPath, "report.md", "\(arguments)")
        }
    }

    /// A folder given is where the clips are, WAVs or kept recordings.
    func testAFolderGivenIsReadEitherWay() throws {
        XCTAssertEqual(try BenchOptions.parse(["/clips"], support: support).source,
                       .wavs(URL(fileURLWithPath: "/clips", isDirectory: true)))
        XCTAssertEqual(try BenchOptions.parse(["/clips", "--from-archive"], support: support).source,
                       .archive(URL(fileURLWithPath: "/clips", isDirectory: true)))
    }

    /// A misspelt flag is refused rather than taken for a folder, and so is
    /// `--output` with no file or a second folder.
    func testBadArgumentsAreRefused() {
        for arguments in [["--output"], ["--from-archiv"], ["--archive"], ["one", "two"]] {
            XCTAssertThrowsError(try BenchOptions.parse(arguments, support: support), "\(arguments)")
        }
        XCTAssertTrue(BenchOptions.usage.contains("--from-archive"))
    }

    // MARK: - Clips

    /// The archive's clips are its `<uuid>.m4a` files, by name; anything
    /// else there is left alone. Without the flag only WAVs are read.
    func testTheArchiveListsOnlyItsRecordings() throws {
        let archive = AudioArchive(directory: directory)
        let first = try archive.save(clip(seconds: 1), id: UUID())
        let second = try archive.save(clip(seconds: 2), id: UUID())
        try clip(seconds: 1).writeWAV(to: directory.appendingPathComponent("1762900000000.wav"))
        try Data("notes".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.m4a"),
                                                withIntermediateDirectories: true)

        let kept = BenchOptions(source: .archive(directory), outputPath: "r.md").clipFiles()
        XCTAssertEqual(kept.map(\.lastPathComponent), [first, second].sorted())
        let wavs = BenchOptions(source: .wavs(directory), outputPath: "r.md").clipFiles()
        XCTAssertEqual(wavs.map(\.lastPathComponent), ["1762900000000.wav"])
    }

    /// Kept recordings load through the same path as WAVs,
    /// `AudioClip(contentsOf:)`, as 16 kHz clips, each named by its uuid file
    /// name alone, so the report shows no folder. One that cannot be read is
    /// skipped, with the reason.
    func testKeptRecordingsLoadAsClipsNamedByTheirUUIDs() throws {
        let archive = AudioArchive(directory: directory)
        let name = try archive.save(clip(seconds: 2), id: UUID())
        try Data("not audio".utf8).write(to: directory.appendingPathComponent("broken.m4a"))
        let files = BenchOptions(source: .archive(directory), outputPath: "r.md").clipFiles()

        let loaded = BenchOptions.loadClips(files)

        XCTAssertEqual(loaded.clips.map(\.name), [name])
        XCTAssertEqual(try XCTUnwrap(loaded.clips.first).clip.samples.count, 32_000)
        XCTAssertEqual(loaded.skipped.map(\.name), ["broken.m4a"])
        XCTAssertFalse(try XCTUnwrap(loaded.skipped.first).reason.isEmpty)
        let report = BenchReport.markdown(rows: loaded.clips.map {
            BenchReport.Row(clip: $0.name, audioSeconds: $0.clip.duration, model: "appleSpeech/en-US", text: "Hello.", seconds: 0.2)
        })
        XCTAssertTrue(report.contains("## \(name)\n"))
        XCTAssertFalse(report.contains(directory.path), "the report names clips, not where they are")
        XCTAssertFalse(report.contains(directory.lastPathComponent), "nor the folder they are in")
    }

    private func clip(seconds: Int) -> AudioClip {
        AudioClip(samples: (0..<(16_000 * seconds)).map { Float($0 % 100) / 200 })
    }
}
