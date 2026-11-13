import XCTest
@testable import VoiceDictationLib

/// Task 21's cleanup step, with a fake cleaner, recorder and paster, over a
/// real `TranscriptionService` running `FakeEngine`s (Ruling P12).
///
/// Review Focus 3: whatever a cleanup does wrong (adds a word, explains
/// instead, refuses, fails, or runs past its time limit), the raw text is
/// pasted, the dictation is reported, and no error shows.
final class CleanupPipelineTests: XCTestCase {
    private let recorder = FakeRecorder()
    private let paster = FakePaster()
    private let cleaner = FakeCleaner()
    private var outcomes: [DictationOutcome] = []
    private var lateCleanups: [(id: UUID, text: String, seconds: Double)] = []
    /// What the pipeline's `cleanupEnabled` reads, dictation by dictation.
    private var cleanupOn = true
    private let clip = AudioClip(samples: [Float](repeating: 0.2, count: 16_000))
    private let raw = "um so i think we should uh ship it"
    private let cleaned = "I think we should ship it."

    // MARK: - In time

    @MainActor
    func testCleanedTextIsPastedWhenAccepted() async throws {
        let pipeline = makePipeline(engineText: raw)
        cleaner.reply = { [cleaned] _ in cleaned }
        cleaner.delay = 0.05

        dictate(on: pipeline)
        try await waitUntil("the dictation finishes") { outcomes.count == 1 }

        XCTAssertEqual(cleaner.given, [raw], "the cleaner gets the service's text")
        XCTAssertEqual(paster.pasted, [cleaned])
        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(outcome.text, cleaned)
        XCTAssertEqual(outcome.rawText, raw)
        XCTAssertEqual(outcome.cleanedText, cleaned)
        let seconds = try XCTUnwrap(outcome.cleanupSeconds)
        XCTAssertGreaterThanOrEqual(seconds, 0.05)
        XCTAssertLessThan(seconds, DictationPipeline.cleanupTimeLimit)
        XCTAssertEqual(outcome.status, .pasted)
        XCTAssertEqual(pipeline.state, .idle)
        pipeline.pasteLast()
        XCTAssertEqual(paster.pasted, [cleaned, cleaned], "paste last pastes what was pasted")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(lateCleanups.isEmpty, "a cleanup in time is no late cleanup")
    }

    /// A cleanup that changes a word, explains itself, refuses in words or
    /// adds a word is rejected: the raw text is pasted and nothing is shown.
    @MainActor
    func testRawPastedWhenGuardRejects() async throws {
        let pipeline = makePipeline(engineText: raw)
        let replies = ["We must ship it.", "Here is the cleaned text: I think we should ship it.",
                       "I can't help with that.", "I think we should ship it on Friday."]

        for (index, reply) in replies.enumerated() {
            cleaner.reply = { _ in reply }
            dictate(on: pipeline)
            try await waitUntil("dictation \(index + 1) finishes") { outcomes.count == index + 1 }
        }

        XCTAssertEqual(cleaner.given.count, replies.count)
        XCTAssertEqual(paster.pasted, Array(repeating: raw, count: replies.count))
        for outcome in outcomes {
            XCTAssertNil(outcome.cleanedText)
            XCTAssertNil(outcome.cleanupSeconds)
            XCTAssertEqual(outcome.text, raw)
            XCTAssertEqual(outcome.rawText, raw)
            XCTAssertEqual(outcome.status, .pasted)
        }
        XCTAssertEqual(pipeline.state, .idle, "a rejected cleanup shows no error")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(lateCleanups.isEmpty)
    }

    /// The error state would stay on show for `errorDisplaySeconds` (5 s),
    /// so a state that is idle right after the paste never showed one.
    @MainActor
    func testRawPastedWhenCleanerThrows() async throws {
        let pipeline = makePipeline(engineText: raw)
        let errors: [Error] = [TranscriptionError.failed("The model refused"), CancellationError()]

        for (index, error) in errors.enumerated() {
            cleaner.error = error
            dictate(on: pipeline)
            try await waitUntil("dictation \(index + 1) finishes") { outcomes.count == index + 1 }
            XCTAssertEqual(pipeline.state, .idle, "\(error) showed as an error")
        }

        XCTAssertEqual(cleaner.given, [raw, raw], "the cleaner was asked")
        XCTAssertEqual(paster.pasted, [raw, raw])
        XCTAssertEqual(outcomes.map(\.status), [.pasted, .pasted])
        XCTAssertEqual(outcomes.map(\.cleanedText), [nil, nil])
        XCTAssertEqual(outcomes.map(\.failure), [nil, nil])
    }

    // MARK: - Late

    /// The real time limit: a cleanup still running after 2 s is not waited
    /// for. The raw text pastes then; the cleanup's result, when it comes and
    /// passes the guard, is reported once through `onLateCleanup`, with the
    /// outcome's id, and nothing is pasted again.
    @MainActor
    func testRawPastedAtTimeLimit() async throws {
        let pipeline = makePipeline(engineText: raw)
        cleaner.reply = { [cleaned] _ in cleaned }
        cleaner.delay = 5

        dictate(on: pipeline)
        let keyUp = ContinuousClock.now
        try await waitUntil("the raw text pastes", within: 4) { outcomes.count == 1 }
        let pastedAfter = Self.seconds(keyUp.duration(to: .now))

        XCTAssertGreaterThanOrEqual(pastedAfter, 1.9, "pasted before the time limit")
        XCTAssertLessThan(pastedAfter, 3, "pasted long after the time limit")
        XCTAssertEqual(paster.pasted, [raw])
        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(outcome.text, raw)
        XCTAssertNil(outcome.cleanedText)
        XCTAssertNil(outcome.cleanupSeconds)
        XCTAssertEqual(pipeline.state, .idle, "the late cleanup runs unseen")
        XCTAssertTrue(lateCleanups.isEmpty)

        try await waitUntil("the late cleanup arrives", within: 5) { lateCleanups.count == 1 }
        let late = try XCTUnwrap(lateCleanups.first)
        XCTAssertEqual(late.id, outcome.id)
        XCTAssertEqual(late.text, cleaned)
        XCTAssertGreaterThanOrEqual(late.seconds, 5)
        XCTAssertLessThan(late.seconds, 6)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(lateCleanups.count, 1, "reported once")
        XCTAssertEqual(paster.pasted, [raw], "nothing is pasted again")
        XCTAssertEqual(outcomes.count, 1)
    }

    /// A late result the guard rejects, or a late failure, never reaches
    /// `onLateCleanup`.
    @MainActor
    func testLateRejectedCleanupIsDropped() async throws {
        let pipeline = makePipeline(engineText: raw)
        pipeline.cleanupLimitSeconds = 0.2
        cleaner.delay = 0.5
        cleaner.reply = { _ in "We must ship it." }

        dictate(on: pipeline)
        try await waitUntil("the raw text pastes") { outcomes.count == 1 }
        try await waitUntil("the rejected cleanup ends") { cleaner.finishedCount == 1 }
        cleaner.reply = nil
        cleaner.error = TranscriptionError.failed("The model failed")
        dictate(on: pipeline)
        try await waitUntil("the second raw text pastes") { outcomes.count == 2 }
        try await waitUntil("the failed cleanup ends") { cleaner.finishedCount == 2 }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(lateCleanups.isEmpty)
        XCTAssertEqual(paster.pasted, [raw, raw])
        XCTAssertEqual(outcomes.map(\.cleanedText), [nil, nil])
        XCTAssertEqual(pipeline.state, .idle)
    }

    // MARK: - Skipped

    /// Transcripts under `cleanupMinimumWords` (4) words skip cleanup.
    @MainActor
    func testShortTranscriptSkipsCleanup() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.result = "ship it now"
        let pipeline = makePipeline(apple)
        cleaner.reply = { _ in "Ship it now." }

        dictate(on: pipeline)
        try await waitUntil("the three words paste") { outcomes.count == 1 }
        XCTAssertEqual(cleaner.given, [], "the cleaner was called for three words")
        XCTAssertEqual(paster.pasted, ["ship it now"])
        XCTAssertNil(outcomes.first?.cleanedText)

        apple.result = "ship it now please"
        cleaner.reply = { _ in "Ship it now, please." }
        dictate(on: pipeline)
        try await waitUntil("the four words paste") { outcomes.count == 2 }
        XCTAssertEqual(cleaner.given, ["ship it now please"], "four words are cleaned")
        XCTAssertEqual(paster.pasted.last, "Ship it now, please.")
    }

    /// The setting is read for each dictation.
    @MainActor
    func testCleanupOffSkipsCleaner() async throws {
        let pipeline = makePipeline(engineText: raw)
        cleaner.reply = { [cleaned] _ in cleaned }
        cleanupOn = false

        dictate(on: pipeline)
        try await waitUntil("the dictation finishes") { outcomes.count == 1 }
        XCTAssertEqual(cleaner.given, [])
        XCTAssertEqual(paster.pasted, [raw])
        XCTAssertNil(outcomes.first?.cleanedText)
        XCTAssertNil(outcomes.first?.cleanupSeconds)
        XCTAssertEqual(cleaner.prewarmCount, 0, "a cleaner that is off is not readied")
        pipeline.prewarmCleanup()
        XCTAssertEqual(cleaner.prewarmCount, 0)

        cleanupOn = true
        dictate(on: pipeline)
        try await waitUntil("the next dictation finishes") { outcomes.count == 2 }
        XCTAssertEqual(paster.pasted, [raw, cleaned])
    }

    /// A cleaner that cannot run now (Apple Intelligence off, say) is not
    /// asked: the raw text pastes at once.
    @MainActor
    func testUnavailableCleanerIsSkipped() async throws {
        let pipeline = makePipeline(engineText: raw)
        cleaner.isAvailable = false

        dictate(on: pipeline)
        try await waitUntil("the dictation finishes") { outcomes.count == 1 }

        XCTAssertEqual(cleaner.given, [])
        XCTAssertEqual(paster.pasted, [raw])
        XCTAssertEqual(cleaner.prewarmCount, 0)

        cleaner.isAvailable = true
        cleaner.reply = { [cleaned] _ in cleaned }
        dictate(on: pipeline)
        try await waitUntil("the next dictation finishes") { outcomes.count == 2 }
        XCTAssertEqual(cleaner.given, [raw], "asked once it can run")
        XCTAssertEqual(paster.pasted, [raw, cleaned])
    }

    @MainActor
    func testCleanupEnabledDefaultsToOn() {
        let preferences = PreferencesManager(defaults: MemoryPreferenceStore())
        XCTAssertTrue(preferences.cleanupEnabled)
        preferences.cleanupEnabled = false
        XCTAssertFalse(preferences.cleanupEnabled)
        preferences.cleanupEnabled = true
        XCTAssertTrue(preferences.cleanupEnabled)
    }

    // MARK: - State, order and timing

    @MainActor
    func testStateShowsCleaning() async throws {
        let pipeline = makePipeline(engineText: raw)
        cleaner.isHeld = true

        dictate(on: pipeline)
        XCTAssertEqual(pipeline.state, .transcribing)
        try await waitUntil("the cleanup starts") { cleaner.given.count == 1 }
        XCTAssertEqual(pipeline.state, .cleaning)
        XCTAssertEqual(pipeline.dictationsInFlight, 1)
        cleaner.isHeld = false
        try await waitUntil("the dictation finishes") { outcomes.count == 1 }

        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertEqual(pipeline.dictationsInFlight, 0)
    }

    /// Ruling T21-1: the order is OutputFilter (in the service, Ruling P3),
    /// then the replacements, then the cleaner, then the guard and the paste.
    /// Until Task 22 the replacements change nothing, so the cleaner gets the
    /// service's text as it is.
    @MainActor
    func testReplacementsRunBetweenTheServiceAndTheCleaner() async throws {
        let order = OrderLog()
        let apple = FakeEngine(kind: .appleSpeech)
        apple.textForClip = { [raw] _ in
            order.append("transcribe")
            return raw
        }
        let pipeline = makePipeline(apple, replacements: {
            order.append("replacements")
            return []
        })
        cleaner.onClean = { text in order.append("clean: \(text)") }
        cleaner.reply = { [cleaned] _ in cleaned }

        dictate(on: pipeline)
        try await waitUntil("the dictation finishes") { outcomes.count == 1 }

        XCTAssertEqual(order.entries, ["transcribe", "replacements", "clean: \(raw)"])
        XCTAssertEqual(paster.pasted, [cleaned])
        XCTAssertEqual(outcomes.first?.rawText, raw, "the raw text is the cleaner's input")
    }

    /// A dictation transcribed while the one before it is cleaned up waits
    /// for that paste: each pastes once, in the order they were made.
    @MainActor
    func testDictationsPasteInOrderAroundACleanup() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.textForClip = { clip in "number \(Int(clip.samples[0])) um is ready now" }
        let pipeline = makePipeline(apple)
        cleaner.reply = { $0.replacingOccurrences(of: " um", with: "") }
        cleaner.isHeld = true

        dictate(numbered(1), on: pipeline)
        try await waitUntil("the first is cleaned up") { cleaner.given.count == 1 }
        dictate(numbered(2), on: pipeline)
        try await waitUntil("the second is transcribed meanwhile") { apple.transcribedClips.count == 2 }
        XCTAssertEqual(pipeline.state, .cleaning)
        XCTAssertEqual(paster.pasted, [])
        cleaner.isHeld = false
        try await waitUntil("both finish") { outcomes.count == 2 }

        XCTAssertEqual(paster.pasted, ["number 1 is ready now", "number 2 is ready now"])
        XCTAssertEqual(outcomes.map(\.text), ["number 1 is ready now", "number 2 is ready now"])
        XCTAssertEqual(outcomes.map(\.clip), [numbered(1), numbered(2)])
        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertEqual(pipeline.dictationsInFlight, 0)
    }

    /// Ruling P5: the timing line adds cleanup's interval when it ran.
    @MainActor
    func testTimingAddsTheCleanupIntervalWhenCleanupRan() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.result = raw
        let pipeline = makePipeline(apple)
        cleaner.reply = { [cleaned] _ in cleaned }
        cleaner.delay = 0.05

        pipeline.hotkeyDown()
        recorder.onFirstAudio?(Date())
        recorder.nextClip = clip
        pipeline.hotkeyUp()
        try await waitUntil("the cleaned dictation finishes") { outcomes.count == 1 }
        let cleanedTiming = try XCTUnwrap(pipeline.lastTiming)
        let cleanup = try XCTUnwrap(cleanedTiming.milliseconds(from: .textReady, to: .cleaned))
        XCTAssertGreaterThanOrEqual(cleanup, 50)
        XCTAssertNotNil(cleanedTiming.milliseconds(from: .cleaned, to: .pasted))
        XCTAssertTrue(cleanedTiming.summary.hasSuffix(" text→cleaned=\(cleanup)ms"), cleanedTiming.summary)
        XCTAssertEqual(cleanedTiming.summary.split(separator: " ").count, 4, cleanedTiming.summary)

        apple.result = "ship it now"
        dictate(on: pipeline)
        try await waitUntil("the short dictation finishes") { outcomes.count == 2 }
        let skippedTiming = try XCTUnwrap(pipeline.lastTiming)
        XCTAssertNil(skippedTiming.milliseconds(from: .textReady, to: .cleaned))
        XCTAssertFalse(skippedTiming.summary.contains("cleaned"), skippedTiming.summary)
    }

    /// The cleaner is readied after each dictation, and at launch through
    /// `prewarmCleanup()`.
    @MainActor
    func testCleanerIsPrewarmedAfterEachDictation() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.result = "ship it"
        let pipeline = makePipeline(apple)
        pipeline.prewarmCleanup()
        XCTAssertEqual(cleaner.prewarmCount, 1)

        dictate(on: pipeline)
        try await waitUntil("the dictation finishes") { outcomes.count == 1 }
        XCTAssertEqual(cleaner.prewarmCount, 2, "readied after a dictation, also one too short to clean")

        apple.result = raw
        dictate(on: pipeline)
        try await waitUntil("the next dictation finishes") { outcomes.count == 2 }
        XCTAssertEqual(cleaner.prewarmCount, 3)
    }

    // MARK: - Cancelling (no late cleanup)

    /// `cancel()` while a dictation is cleaned up leaves no trace: nothing is
    /// pasted or reported, then or when the cleaner replies after all, and
    /// the next dictation works as usual.
    @MainActor
    func testCancelWhileCleaningLeavesNoTrace() async throws {
        let pipeline = makePipeline(engineText: raw)
        cleaner.reply = { [cleaned] _ in cleaned }
        cleaner.ignoresCancellation = true
        cleaner.isHeld = true

        dictate(on: pipeline)
        try await waitUntil("the cleanup starts") { cleaner.given.count == 1 }
        pipeline.cancel()
        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertEqual(pipeline.dictationsInFlight, 0)
        cleaner.isHeld = false
        try await waitUntil("the cleaner replies all the same") { cleaner.finishedCount == 1 }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(paster.pasted, [])
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertTrue(lateCleanups.isEmpty)

        cleaner.ignoresCancellation = false
        dictate(on: pipeline)
        try await waitUntil("the next dictation finishes") { outcomes.count == 1 }
        XCTAssertEqual(paster.pasted, [cleaned])
    }

    /// The hotkey's cancel reaches this hold's dictation while it is cleaned
    /// up: the recorder ended the recording by itself while Globe stayed
    /// down, and a key pressed with Globe cancels it.
    @MainActor
    func testHotkeyCancelWhileCleaningLeavesNoTrace() async throws {
        let pipeline = makePipeline(engineText: raw)
        cleaner.reply = { [cleaned] _ in cleaned }
        cleaner.ignoresCancellation = true
        cleaner.isHeld = true

        pipeline.hotkeyDown()
        recorder.nextClip = clip
        recorder.stopRecording()
        try await waitUntil("the cleanup starts") { cleaner.given.count == 1 }
        pipeline.cancelHold()
        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertEqual(pipeline.dictationsInFlight, 0)
        pipeline.hotkeyUp()
        cleaner.isHeld = false
        try await waitUntil("the cleaner replies all the same") { cleaner.finishedCount == 1 }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(paster.pasted, [])
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertTrue(lateCleanups.isEmpty)
    }

    // MARK: - Helpers

    @MainActor
    private func makePipeline(engineText: String) -> DictationPipeline {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.result = engineText
        return makePipeline(apple)
    }

    @MainActor
    private func makePipeline(_ engine: FakeEngine,
                              replacements: @escaping () -> [Replacement] = { [] }) -> DictationPipeline {
        let service = TranscriptionService(engines: [engine], selected: .appleSpeech)
        let pipeline = DictationPipeline(recorder: recorder, service: service, paster: paster, cleaner: cleaner,
                                         replacements: replacements, vocabulary: { [] },
                                         cleanupEnabled: { [weak self] in self?.cleanupOn ?? false })
        pipeline.onOutcome = { [weak self] outcome in self?.outcomes.append(outcome) }
        pipeline.onLateCleanup = { [weak self] id, text, seconds in self?.lateCleanups.append((id, text, seconds)) }
        return pipeline
    }

    /// Holds the hotkey while the recorder captures `clip`, then lets go.
    @MainActor
    private func dictate(_ clip: AudioClip? = nil, on pipeline: DictationPipeline) {
        pipeline.hotkeyDown()
        recorder.nextClip = clip ?? self.clip
        pipeline.hotkeyUp()
    }

    /// A clip the fake engine can tell apart: its first sample is `number`.
    private func numbered(_ number: Int) -> AudioClip {
        AudioClip(samples: [Float(number)] + [Float](repeating: 0.2, count: 16_000))
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// What happened, in order, across the engine, the pipeline and the cleaner.
    private final class OrderLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _entries: [String] = []

        var entries: [String] { lock.withLock { _entries } }
        func append(_ entry: String) { lock.withLock { _entries.append(entry) } }
    }

    private struct Timeout: Error {}

    /// Polls every 10 ms until `condition` holds. Fails the test after
    /// `limit` seconds instead of hanging.
    @MainActor
    private func waitUntil(_ what: String, within limit: TimeInterval = 2,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(limit)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Waited \(limit) s for: \(what)", file: file, line: line)
                throw Timeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
