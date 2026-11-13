import Speech
import XCTest
@testable import VoiceDictationLib

/// A whole dictation, from a recorded clip to the stored transcript, with
/// only the microphone, the paste and the cleaner faked.
final class EndToEndTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    @MainActor
    func testSampleFlowsFromClipToStore() async throws {
        try await skipUnlessAppleSpeechInstalled()
        try await assertSampleFlowsFromClipToStore(engine: AppleSpeechEngine(), selected: .appleSpeech)
    }

    /// The same run with the default, whisper.cpp base.en, read from the
    /// app's own models folder, which this test only reads.
    @MainActor
    func testSampleFlowsFromClipToStoreWithWhisperCppBase() async throws {
        let models = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appending(path: "VoiceDictation/models", directoryHint: .isDirectory)
        let engine = WhisperCppEngine(directory: models)
        guard await engine.models().first(where: { $0.id == .whisperCppBase })?.state == .ready else {
            throw XCTSkip("ggml-base.en.bin is not in \(models.path)")
        }
        try await assertSampleFlowsFromClipToStore(engine: engine, selected: .whisperCppBase)
    }

    /// The sample recorded, transcribed by `engine`'s `selected` model,
    /// cleaned up, pasted once and kept in the store with its recording.
    @MainActor
    private func assertSampleFlowsFromClipToStore(engine: TranscriptionEngine, selected: ModelID) async throws {
        let rig = try makeRig(engine: engine, selected: selected)
        let cleaner = FakeCleaner()
        let pipeline = rig.pipeline(cleaner: cleaner, cleanupEnabled: { true })
        rig.recorder.nextClip = try sample()

        let finished = expectation(description: "the dictation finishes")
        rig.onOutcome = { finished.fulfill() }
        pipeline.hotkeyDown()
        pipeline.hotkeyUp()
        await fulfillment(of: [finished], timeout: 30)

        let pasted = try XCTUnwrap(rig.paster.pasted.first)
        XCTAssertTrue(pasted.lowercased().contains("quick brown fox"), "pasted: \(pasted)")
        XCTAssertEqual(rig.paster.pasted.count, 1)
        XCTAssertEqual(cleaner.given.count, 1, "the text went through cleanup and its guard")
        XCTAssertEqual(rig.store.count(scope: .all), 1)
        let transcript = try XCTUnwrap(rig.store.latest)
        XCTAssertEqual(transcript.status, .pasted)
        XCTAssertEqual(transcript.text, pasted)
        XCTAssertEqual(transcript.modelKey, selected.storageKey)
        XCTAssertGreaterThan(transcript.transcribeSeconds, 0)
        let fileName = try XCTUnwrap(transcript.audioFileName, "the recording was saved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.audio.url(for: fileName).path))
        XCTAssertEqual(pipeline.state, .idle)
    }

    @MainActor
    func testSilentClipProducesNothing() throws {
        let engine = FakeEngine(kind: .appleSpeech)
        let rig = try makeRig(engine: engine, selected: .appleSpeech)
        let pipeline = rig.pipeline(cleaner: nil, cleanupEnabled: { true })
        // Two seconds of zeros: long enough to keep, but silent.
        rig.recorder.nextClip = AudioClip(samples: [Float](repeating: 0, count: 32_000))

        pipeline.hotkeyDown()
        pipeline.hotkeyUp()

        // The recorder's verdict discards it at once, so nothing is in flight.
        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertEqual(pipeline.dictationsInFlight, 0)
        XCTAssertEqual(engine.calls, [], "no engine call")
        XCTAssertEqual(rig.paster.pasted, [])
        XCTAssertEqual(rig.paster.copied, [])
        XCTAssertEqual(rig.outcomeCount, 0)
        XCTAssertEqual(rig.store.count(scope: .all), 0)
        XCTAssertEqual(rig.audio.fileNames(), [])
    }

    // MARK: - Helpers

    /// The pieces of one dictation setup. A class, so the outcome handler can
    /// reach the store and the test's expectation.
    @MainActor
    private final class Rig {
        let recorder = FakeRecorder()
        let paster = FakePaster()
        let service: TranscriptionService
        let store: TranscriptStore
        let audio: AudioArchive
        var onOutcome: (() -> Void)?
        private(set) var outcomeCount = 0

        init(service: TranscriptionService, store: TranscriptStore, audio: AudioArchive) {
            self.service = service
            self.store = store
            self.audio = audio
            recorder.appliesRealVerdict = true
        }

        func pipeline(cleaner: TextCleaner?, cleanupEnabled: @escaping () -> Bool) -> DictationPipeline {
            let pipeline = DictationPipeline(recorder: recorder, service: service, paster: paster,
                                             cleaner: cleaner, replacements: { [] }, vocabulary: { [] },
                                             cleanupEnabled: cleanupEnabled)
            pipeline.onOutcome = { [weak self] outcome in
                guard let self else { return }
                outcomeCount += 1
                store.add(outcome)
                onOutcome?()
            }
            return pipeline
        }
    }

    @MainActor
    private func makeRig(engine: TranscriptionEngine, selected: ModelID) throws -> Rig {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vd-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let audio = AudioArchive(directory: directory.appendingPathComponent("audio"))
        let store = TranscriptStore(directory: directory, inMemory: true, audio: audio, keptRecordings: { 10 })
        let service = TranscriptionService(engines: [engine], selected: selected)
        return Rig(service: service, store: store, audio: audio)
    }

    private func sample() throws -> AudioClip {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "wav", subdirectory: "Resources"))
        return try AudioClip(contentsOf: url)
    }

    /// Skips unless Apple Speech supports en-US here and its language files
    /// are installed for this test process (macOS reserves them per app).
    private func skipUnlessAppleSpeechInstalled() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw XCTSkip("SpeechTranscriber is not available on this Mac")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw XCTSkip("SpeechTranscriber does not support en-US on this Mac")
        }
        let status = await AssetInventory.status(forModules: [SpeechTranscriber(locale: locale, preset: .transcription)])
        guard status == .installed else {
            throw XCTSkip("appleSpeech: en-US language files are not installed for this test process "
                + "(status: \(status)). See Task 6 in docs/superpowers/plans/2026-11-11-native-app-notes.md.")
        }
    }
}
