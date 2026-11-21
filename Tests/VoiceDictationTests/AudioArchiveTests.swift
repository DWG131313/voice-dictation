import SwiftData
import XCTest
@testable import VoiceDictationLib

/// The audio archive and the store's retention of recordings. Every test
/// uses a temporary folder and an in-memory store (Ruling T12-2): never
/// Danny's real `audio/` folder or `transcripts.store`.
final class AudioArchiveTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_762_900_000)
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vd-audio-\(UUID().uuidString)", isDirectory: true)
        directories.append(directory)
        return directory
    }

    private func clip(_ seed: Float = 0.1) -> AudioClip {
        AudioClip(samples: (0..<3_200).map { seed * sin(Float($0) / 20) })
    }

    @MainActor
    private func makeStore(keeping: Int, archive: AudioArchive) -> TranscriptStore {
        let unused = FileManager.default.temporaryDirectory.appendingPathComponent("vd-unused-\(UUID().uuidString)")
        let store = TranscriptStore(directory: unused, inMemory: true, audio: archive, keptRecordings: { keeping })
        XCTAssertEqual(store.health, .ok)
        return store
    }

    private func outcome(_ n: Int, status: DictationOutcome.Status = .pasted, clip: AudioClip? = nil) -> DictationOutcome {
        let failed = status == .failed
        return DictationOutcome(
            id: UUID(), date: base.addingTimeInterval(Double(n)), clip: clip ?? self.clip(),
            rawText: failed ? "" : "text \(n)", text: failed ? "" : "text \(n)", model: .appleSpeech,
            transcribeSeconds: 0.1, appName: nil, status: status, failure: failed ? "failed" : nil
        )
    }

    private func files(_ archive: AudioArchive) -> [String] { archive.fileNames().sorted() }

    // MARK: - The archive

    func testSaveLoadRoundTrip() throws {
        let archive = AudioArchive(directory: try makeDirectory().appendingPathComponent("audio"))
        let original = clip()
        let id = UUID()

        let name = try archive.save(original, id: id)

        XCTAssertEqual(name, id.uuidString + ".m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.url(for: name).path))
        let loaded = try archive.load(name)
        XCTAssertEqual(loaded.samples.count, original.samples.count)
        for (a, b) in zip(loaded.samples, original.samples) { XCTAssertEqual(a, b, accuracy: 0.001) }

        archive.remove(name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.url(for: name).path))
        archive.remove(name) // already gone: no error
    }

    // MARK: - Retention

    @MainActor
    func testPruneKeepsNewestN() throws {
        let archive = AudioArchive(directory: try makeDirectory())
        let store = makeStore(keeping: 50, archive: archive)
        for n in 0..<60 { XCTAssertNotNil(store.add(outcome(n))) }

        let all = store.search("", scope: .all) // newest first
        XCTAssertEqual(all.count, 60)
        XCTAssertTrue(all.prefix(50).allSatisfy { $0.audioFileName != nil })
        XCTAssertTrue(all.suffix(10).allSatisfy { $0.audioFileName == nil }, "the oldest ten lose their audio")
        XCTAssertEqual(files(archive).count, 50)
        for t in all.prefix(50) { XCTAssertTrue(files(archive).contains(try XCTUnwrap(t.audioFileName))) }
    }

    @MainActor
    func testPruneAppliesALowerLimitToWhatIsAlreadyKept() throws {
        let archive = AudioArchive(directory: try makeDirectory())
        let store = makeStore(keeping: 5, archive: archive)
        for n in 0..<5 { store.add(outcome(n)) }
        store.prune(keeping: 2)
        let all = store.search("", scope: .all)
        XCTAssertEqual(all.compactMap(\.audioFileName).count, 2)
        XCTAssertEqual(files(archive).count, 2)
    }

    @MainActor
    func testPinnedKeepAudioAndDoNotCountAgainstLimit() throws {
        let archive = AudioArchive(directory: try makeDirectory())
        let store = makeStore(keeping: 2, archive: archive)
        let oldest = try XCTUnwrap(store.add(outcome(0)))
        store.setPinned(oldest, true)
        for n in 1...4 { store.add(outcome(n)) }

        let all = store.search("", scope: .all)
        XCTAssertNotNil(oldest.audioFileName, "pinned keeps its audio")
        XCTAssertEqual(all.filter { $0.audioFileName != nil && !$0.pinned }.count, 2, "pinned is not counted")
        XCTAssertEqual(files(archive).count, 3)
    }

    // MARK: - Expiry after a week (Danny, 2026-11-20)

    /// A store whose recordings last a week, read at `days` after `base`.
    @MainActor
    private func makeWeekStore(archive: AudioArchive, daysLater days: Double) -> TranscriptStore {
        let unused = FileManager.default.temporaryDirectory.appendingPathComponent("vd-unused-\(UUID().uuidString)")
        let now = base.addingTimeInterval(days * 86_400)
        let store = TranscriptStore(directory: unused, inMemory: true, now: now, audio: archive,
                                    keptRecordings: { 50 }, recordingLifetime: TranscriptStore.weekOfRecordings,
                                    clock: { now })
        XCTAssertEqual(store.health, .ok)
        return store
    }

    @MainActor
    func testARecordingOlderThanAWeekExpiresAndItsTranscriptStays() throws {
        let archive = AudioArchive(directory: try makeDirectory())
        let store = makeWeekStore(archive: archive, daysLater: 8)
        let old = try XCTUnwrap(store.add(outcome(0)))                  // 8 days old
        let recent = try XCTUnwrap(store.add(outcome(2 * 86_400)))      // 6 days old
        let today = try XCTUnwrap(store.add(outcome(8 * 86_400 - 60)))  // a minute old

        XCTAssertNil(old.audioFileName, "older than a week: the recording goes")
        XCTAssertNotNil(recent.audioFileName)
        XCTAssertNotNil(today.audioFileName)
        XCTAssertEqual(store.search("", scope: .all).count, 3, "every transcript stays")
        XCTAssertEqual(files(archive).count, 2)
    }

    @MainActor
    func testPinnedAndFailedRecordingsDoNotExpire() throws {
        let archive = AudioArchive(directory: try makeDirectory())
        let store = makeWeekStore(archive: archive, daysLater: 30)
        let failed = try XCTUnwrap(store.add(outcome(0, status: .failed)))
        // Pinned while still fresh; read again three weeks on.
        let pinned = try XCTUnwrap(store.add(outcome(30 * 86_400 - 60)))
        store.setPinned(pinned, true)
        let later = base.addingTimeInterval(51 * 86_400)
        store.prune(keeping: 50, now: later)

        XCTAssertNotNil(failed.audioFileName, "a failed dictation keeps its recording")
        XCTAssertNotNil(pinned.audioFileName, "a pinned one keeps its recording")
    }

    /// `pruneRecordings` applies the store's own limits, judged now: a
    /// recording that aged past a week since it was kept goes.
    @MainActor
    func testPruneRecordingsRemovesWhatAgedPastAWeek() throws {
        let archive = AudioArchive(directory: try makeDirectory())
        let unused = FileManager.default.temporaryDirectory.appendingPathComponent("vd-unused-\(UUID().uuidString)")
        var now = base
        let store = TranscriptStore(directory: unused, inMemory: true, now: base, audio: archive,
                                    keptRecordings: { 50 }, recordingLifetime: TranscriptStore.weekOfRecordings,
                                    clock: { now })
        let t = try XCTUnwrap(store.add(outcome(0)))
        XCTAssertNotNil(t.audioFileName)

        now = base.addingTimeInterval(8 * 86_400)
        store.pruneRecordings()

        XCTAssertNil(t.audioFileName)
        XCTAssertEqual(files(archive), [])
    }

    /// The store the tests have always made keeps recordings of any age.
    @MainActor
    func testWithoutALifetimeNothingExpires() throws {
        let archive = AudioArchive(directory: try makeDirectory())
        let store = makeStore(keeping: 50, archive: archive)
        let old = try XCTUnwrap(store.add(outcome(0)))   // a year old by the real clock
        XCTAssertNotNil(old.audioFileName)
    }

    @MainActor
    func testZeroKeepsNoAudioForNewTranscripts() throws {
        let archive = AudioArchive(directory: try makeDirectory())
        let store = makeStore(keeping: 0, archive: archive)
        let t = try XCTUnwrap(store.add(outcome(1)))
        XCTAssertNil(t.audioFileName)
        XCTAssertEqual(files(archive), [])
    }

    @MainActor
    func testFailedKeepAudioEvenAtZeroAndDoNotCountAgainstLimit() throws {
        let archive = AudioArchive(directory: try makeDirectory())
        let store = makeStore(keeping: 0, archive: archive)
        let failed = try XCTUnwrap(store.add(outcome(1, status: .failed)))
        XCTAssertNotNil(failed.audioFileName, "a failed dictation keeps its recording")
        XCTAssertNil(try XCTUnwrap(store.add(outcome(2))).audioFileName)
        store.prune(keeping: 0)
        XCTAssertNotNil(failed.audioFileName, "prune never takes a failed one's audio")
        XCTAssertEqual(files(archive).count, 1)

        let archive2 = AudioArchive(directory: try makeDirectory())
        let store2 = makeStore(keeping: 1, archive: archive2)
        let failures = try (0..<3).map { try XCTUnwrap(store2.add(outcome($0, status: .failed))) }
        let pasted = [store2.add(outcome(10)), store2.add(outcome(11))]
        XCTAssertTrue(failures.allSatisfy { $0.audioFileName != nil }, "failed ones are not counted")
        XCTAssertNil(pasted[0]?.audioFileName)
        XCTAssertNotNil(pasted[1]?.audioFileName, "one ordinary transcript fits the limit of 1")
    }

    @MainActor
    func testAFailedTranscriptThatSucceedsLaterIsPrunedLikeAnyOther() throws {
        let archive = AudioArchive(directory: try makeDirectory())
        let store = makeStore(keeping: 1, archive: archive)
        let failed = try XCTUnwrap(store.add(outcome(1, status: .failed)))
        store.add(outcome(2))
        failed.statusRaw = DictationOutcome.Status.pasted.rawValue // what re-transcription will do
        store.prune(keeping: 1)
        XCTAssertNil(failed.audioFileName, "older than the kept newest one")
        XCTAssertEqual(files(archive).count, 1)
    }

    @MainActor
    func testDeletingTranscriptRemovesItsAudio() throws {
        let archive = AudioArchive(directory: try makeDirectory())
        let store = makeStore(keeping: 5, archive: archive)
        let t = try XCTUnwrap(store.add(outcome(1)))
        XCTAssertEqual(files(archive).count, 1)
        store.delete(t)
        XCTAssertEqual(files(archive), [])
    }

    @MainActor
    func testOrphanFilesAreRemovedOnPrune() throws {
        let archive = AudioArchive(directory: try makeDirectory())
        let store = makeStore(keeping: 5, archive: archive)
        let t = try XCTUnwrap(store.add(outcome(1)))
        let stray = try archive.save(clip(), id: UUID())
        let note = archive.directory.appendingPathComponent("notes.txt")
        let folder = archive.directory.appendingPathComponent("sub.m4a", isDirectory: true)
        try Data("x".utf8).write(to: note)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        store.prune(keeping: 5)

        XCTAssertFalse(files(archive).contains(stray))
        XCTAssertTrue(files(archive).contains(try XCTUnwrap(t.audioFileName)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path), "not an .m4a: left alone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "a folder: left alone")
    }

    @MainActor
    func testNoClipKeepsNoAudio() throws {
        let archive = AudioArchive(directory: try makeDirectory())
        let store = makeStore(keeping: 5, archive: archive)
        let o = DictationOutcome(date: base, clip: nil, rawText: "", text: "", model: .appleSpeech,
                                 transcribeSeconds: 0, appName: nil, status: .failed, failure: "skipped")
        XCTAssertNil(try XCTUnwrap(store.add(o)).audioFileName)
    }

    func testRecoveryMovesTheArchiveAsideAndTheNextLaunchKeepsIt() throws {
        let directory = try makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("This is not a SQLite database.".utf8).write(to: directory.appendingPathComponent("transcripts.store"))
        let archive = AudioArchive(directory: directory.appendingPathComponent("audio", isDirectory: true))
        let oldName = try archive.save(clip(), id: UUID())

        try MainActor.assumeIsolated {
            let first = TranscriptStore(directory: directory, audio: archive, keptRecordings: { 5 })
            guard case .recovered(let message) = first.health else { return XCTFail("health is \(first.health)") }
            let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            let movedFolder = try XCTUnwrap(left.first { $0.hasPrefix("audio.broken-") }, "left: \(left)")
            XCTAssertFalse(left.contains("audio"), "the new store starts with no archive folder")
            XCTAssertTrue(message.contains(movedFolder), message)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(movedFolder).appendingPathComponent(oldName).path))

            // The next launch: a healthy store, whose first add prunes.
            let second = TranscriptStore(directory: directory, audio: archive, keptRecordings: { 5 })
            XCTAssertEqual(second.health, .ok)
            XCTAssertNotNil(second.add(outcome(1)))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(movedFolder).appendingPathComponent(oldName).path),
                "the old recording is still there")
            XCTAssertEqual(files(archive).count, 1)
        }
    }

    @MainActor
    func testAnArchiveThatCannotBeWrittenStillKeepsTheTranscript() throws {
        let directory = try makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("audio")
        try Data("a file, not a folder".utf8).write(to: blocker)
        let store = makeStore(keeping: 5, archive: AudioArchive(directory: blocker))
        let t = try XCTUnwrap(store.add(outcome(1)))
        XCTAssertNil(t.audioFileName)
        XCTAssertEqual(store.search("", scope: .all).count, 1)
    }

    func testOnlyPlainM4aNamesReachTheArchive() throws {
        let directory = try makeDirectory()
        let archive = AudioArchive(directory: directory.appendingPathComponent("audio", isDirectory: true))
        let name = try archive.save(clip(), id: UUID())
        let outside = directory.appendingPathComponent("outside.m4a")
        try Data("x".utf8).write(to: outside)

        for bad in ["", ".", "..", "../outside.m4a", "a/b.m4a", "notes.txt", "x.m4a/", ".m4a"] {
            XCTAssertNil(archive.validURL(for: bad), "\(bad)")
            archive.remove(bad)
            XCTAssertThrowsError(try archive.load(bad), bad)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio").path))
        XCTAssertNotNil(archive.validURL(for: name))
    }

    func testKeptRecordingsPreference() {
        let preferences = PreferencesManager(defaults: MemoryPreferenceStore())
        XCTAssertEqual(preferences.keptRecordings, 50)
        preferences.keptRecordings = 0
        XCTAssertEqual(preferences.keptRecordings, 0, "0 is kept, not read as unset")
        preferences.keptRecordings = -3
        XCTAssertEqual(preferences.keptRecordings, 0)
    }
}
