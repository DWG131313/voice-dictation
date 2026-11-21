import XCTest
@testable import VoiceDictationLib

/// The pipeline with a fake recorder and paster, over a real
/// `TranscriptionService` running `FakeEngine`s (Ruling P12).
final class DictationPipelineTests: XCTestCase {
    private let recorder = FakeRecorder()
    private let paster = FakePaster()
    private var outcomes: [DictationOutcome] = []
    private let clip = AudioClip(samples: [Float](repeating: 0.2, count: 16_000))
    private let whisperBase = ModelID(engine: .whisperKit, name: "base.en")

    // MARK: - One dictation

    @MainActor
    func testHappyPathPastesAndReportsOutcome() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.result = "Hello there."
        apple.delay = 0.05
        apple.isHeld = true
        paster.frontmostAppName = "Notes"
        let pipeline = makePipeline([apple])
        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertEqual(recorder.prepareCount, 1, "the microphone is readied at the start")

        pipeline.hotkeyDown()
        guard case .recording = pipeline.state else { return XCTFail("not recording: \(pipeline.state)") }
        recorder.nextClip = clip
        pipeline.hotkeyUp()
        XCTAssertEqual(pipeline.state, .transcribing)
        try await waitUntil("the clip reaches the engine") { apple.transcribedClips == [clip] }
        XCTAssertEqual(pipeline.state, .transcribing)
        apple.isHeld = false
        try await waitUntil("the dictation finishes") { outcomes.count == 1 }

        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertEqual(paster.pasted, ["Hello there."])
        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(outcome.status, .pasted)
        XCTAssertEqual(outcome.appName, "Notes")
        XCTAssertEqual(outcome.text, "Hello there.")
        XCTAssertEqual(outcome.rawText, "Hello there.")
        XCTAssertNil(outcome.cleanedText)
        XCTAssertNil(outcome.cleanupSeconds)
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.clip, clip)
        XCTAssertEqual(outcome.model, .appleSpeech)
        XCTAssertGreaterThanOrEqual(outcome.transcribeSeconds, 0.05)
    }

    @MainActor
    func testEmptyTextPastesNothingAndIsNotAnOutcome() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        let pipeline = makePipeline([apple])

        // An engine that heard nothing, then a whole-transcript hallucination
        // the service filters out to nothing.
        for text in ["", "Thank you."] {
            apple.result = text
            dictate(clip, on: pipeline)
            XCTAssertEqual(pipeline.state, .transcribing)
            try await waitUntil("the dictation finishes") { pipeline.state == .idle }
        }

        XCTAssertEqual(apple.transcribedClips.count, 2)
        XCTAssertEqual(paster.pasted, [])
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertEqual(pipeline.dictationsInFlight, 0)
    }

    /// A dictation whose text came back empty has no outcome and pastes
    /// nothing; the dictation after it pastes as usual, and its outcome has
    /// the clip. (Ruling T9-2's report of the empty one's clip went with the
    /// comparison recordings in Task 24.)
    @MainActor
    func testEmptyTextHasNoOutcome() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        let pipeline = makePipeline([apple])

        apple.result = ""
        dictate(clip, on: pipeline)
        try await waitUntil("the first dictation finishes") { pipeline.state == .idle }
        apple.result = "hello"
        dictate(clip, on: pipeline)
        try await waitUntil("the second dictation finishes") { outcomes.count == 1 }

        XCTAssertEqual(apple.transcribedClips.count, 2)
        XCTAssertEqual(outcomes.map(\.status), [.pasted])
        XCTAssertEqual(outcomes.first?.clip, clip)
        XCTAssertEqual(paster.pasted, ["hello"])
    }

    @MainActor
    func testPasteFailureLeavesTextOnClipboardAsCopied() async throws {
        let pipeline = makePipeline([FakeEngine(kind: .appleSpeech)])
        paster.succeeds = false

        dictate(clip, on: pipeline)
        try await waitUntil("the dictation finishes") { outcomes.count == 1 }

        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(outcome.status, .copied)
        XCTAssertEqual(outcome.text, "hello")
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(paster.pasted, ["hello"], "the paster is handed the text, which it leaves on the clipboard")
        XCTAssertEqual(pipeline.state, .idle, "a copied dictation is not an error")
    }

    // MARK: - Review Focus 1: the model is not ready

    /// A dictation made while the model is still loading records as usual and
    /// is pasted once the model is ready.
    @MainActor
    func testDictationWaitsForAModelStillPreparing() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.isPrepareHeld = true
        let (pipeline, service) = makePipelineAndService([apple])
        let launch = Task { await service.prepareSelected() }
        try await waitUntil("the model is preparing") { apple.calls.contains(.prepare(.appleSpeech)) }

        pipeline.hotkeyDown()
        guard case .recording = pipeline.state else { return XCTFail("did not record while the model loads") }
        recorder.nextClip = clip
        pipeline.hotkeyUp()
        try await waitUntil("the dictation is in line") { await service.dictationsInLine == 1 }
        XCTAssertEqual(pipeline.state, .transcribing)
        apple.isPrepareHeld = false
        try await waitUntil("the dictation finishes") { outcomes.count == 1 }

        XCTAssertEqual(outcomes.first?.status, .pasted)
        XCTAssertEqual(paster.pasted, ["hello"])
        await launch.value
    }

    /// A model that cannot load fails the dictation, which is kept as Failed
    /// with its audio; nothing is pasted.
    @MainActor
    func testModelFailureProducesFailedOutcomeWithClip() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.prepareError = TranscriptionError.modelNotReady("Apple Speech language files are not installed")
        let pipeline = makePipeline([apple])
        pipeline.errorDisplaySeconds = 0.5

        dictate(clip, on: pipeline)
        try await waitUntil("the dictation finishes") { outcomes.count == 1 }

        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.clip, clip)
        XCTAssertEqual(outcome.failure, "Apple Speech language files are not installed")
        XCTAssertEqual(outcome.model, .appleSpeech)
        XCTAssertEqual(outcome.rawText, "")
        XCTAssertEqual(outcome.text, "")
        XCTAssertEqual(paster.pasted, [])
        XCTAssertEqual(pipeline.state, .error("Apple Speech language files are not installed"))
        try await waitUntil("the error clears") { pipeline.state == .idle }
        XCTAssertEqual(pipeline.dictationsInFlight, 0)
    }

    /// Each outcome, pasted or failed, carries the folder the front window
    /// was open on.
    @MainActor
    func testOutcomesCarryTheFrontWindowsFolder() async throws {
        paster.frontmostFolder = "Voice Dictation"
        let apple = FakeEngine(kind: .appleSpeech)
        apple.result = "Hello there."
        let pipeline = makePipeline([apple])
        dictate(clip, on: pipeline)
        try await waitUntil("the dictation finishes") { outcomes.count == 1 }
        XCTAssertEqual(outcomes[0].status, .pasted)
        XCTAssertEqual(outcomes[0].project, "Voice Dictation")

        let broken = FakeEngine(kind: .appleSpeech)
        broken.prepareError = TranscriptionError.modelNotReady("not ready")
        let failing = makePipeline([broken])
        failing.errorDisplaySeconds = 0.5
        dictate(clip, on: failing)
        try await waitUntil("the failure is reported") { outcomes.count == 2 }
        XCTAssertEqual(outcomes[1].status, .failed)
        XCTAssertEqual(outcomes[1].project, "Voice Dictation")
    }

    /// A saved choice whose engine is gone fails each dictation the same way,
    /// where the old wiring crashed on a missing transcriber.
    @MainActor
    func testMissingEngineProducesFailedOutcome() async throws {
        let cliBase = ModelID(engine: .whisperCLI, name: "base.en")
        let pipeline = makePipeline([FakeEngine(kind: .appleSpeech)], selected: cliBase)

        dictate(clip, on: pipeline)
        try await waitUntil("the dictation finishes") { outcomes.count == 1 }

        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.clip, clip)
        XCTAssertEqual(outcome.failure, "No engine runs whisperCLI/base.en")
        XCTAssertEqual(outcome.model, cliBase)
    }

    // MARK: - Review Focus 4: several in quick succession

    /// With three waiting, a fifth recording skips the oldest waiting one,
    /// which never reaches the engine and is kept as Failed with its audio.
    /// The others are pasted once each, in order.
    @MainActor
    func testQueueSkipsOldestBeyondThree() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.isHeld = true
        apple.textForClip = { clip in "clip \(Int(clip.samples[0]))" }
        let (pipeline, service) = makePipelineAndService([apple])
        pipeline.errorDisplaySeconds = 0.2
        let clips = (1...5).map(numbered)

        dictate(clips[0], on: pipeline)
        try await waitUntil("clip 1 reaches the engine") { apple.transcribedClips == [clips[0]] }
        for number in 2...4 {
            dictate(clips[number - 1], on: pipeline)
            try await waitUntil("clip \(number) is in line") { await service.dictationsInLine == number }
        }
        dictate(clips[4], on: pipeline)
        XCTAssertEqual(pipeline.state, .error(DictationPipeline.skippedFailure))
        XCTAssertEqual(pipeline.work, .transcribing, "the skip's error hides none of the work in line")
        try await waitUntil("clip 2 is reported") { outcomes.count == 1 }
        try await waitUntil("clip 2 leaves the line") { await service.dictationsInLine == 4 }
        apple.isHeld = false
        try await waitUntil("every dictation finishes") { outcomes.count == 5 }

        XCTAssertEqual(paster.pasted, ["clip 1", "clip 3", "clip 4", "clip 5"])
        XCTAssertEqual(apple.transcribedClips, [clips[0], clips[2], clips[3], clips[4]], "clip 2 reached the engine")
        let skipped = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(skipped.status, .failed)
        XCTAssertEqual(skipped.clip, clips[1])
        XCTAssertEqual(skipped.failure, "Skipped: too many dictations waiting")
        XCTAssertEqual(skipped.model, .appleSpeech)
        XCTAssertEqual(skipped.text, "")
        let pasted = outcomes.dropFirst()
        XCTAssertEqual(pasted.map(\.status), [.pasted, .pasted, .pasted, .pasted])
        XCTAssertEqual(pasted.compactMap(\.clip), [clips[0], clips[2], clips[3], clips[4]])
        XCTAssertEqual(pasted.map(\.text), ["clip 1", "clip 3", "clip 4", "clip 5"])
        try await waitUntil("the pipeline settles") { pipeline.state == .idle }
        XCTAssertEqual(pipeline.dictationsInFlight, 0)
    }

    // MARK: - Cancelling

    /// Escape leaves no trace: cancelled while recording, or while
    /// transcribing with another waiting, nothing is pasted, nothing is
    /// reported, and the pipeline holds no clip.
    @MainActor
    func testCancelLeavesNoTrace() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.isHeld = true
        let (pipeline, service) = makePipelineAndService([apple])

        // While recording.
        pipeline.hotkeyDown()
        recorder.nextClip = clip
        pipeline.cancel()
        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(pipeline.state, .idle)
        pipeline.hotkeyUp()
        XCTAssertEqual(pipeline.dictationsInFlight, 0)

        // While transcribing, with a second dictation waiting behind it.
        dictate(clip, on: pipeline)
        try await waitUntil("the first reaches the engine") { apple.transcribedClips.count == 1 }
        dictate(clip, on: pipeline)
        try await waitUntil("the second is in line") { await service.dictationsInLine == 2 }
        pipeline.cancel()
        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertEqual(pipeline.dictationsInFlight, 0, "the pipeline still holds a clip")
        try await waitUntil("the engine stops") { apple.cancelledCount == 1 }
        try await waitUntil("the line empties") { await service.dictationsInLine == 0 }
        // Time for a stray paste or outcome to show up.
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(apple.transcribedClips.count, 1, "the waiting dictation reached the engine")
        XCTAssertEqual(paster.pasted, [])
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertEqual(pipeline.state, .idle)
    }

    // MARK: - The hotkey's cancel: this hold only

    /// A key pressed while Globe is held (Globe+Right Arrow, or Escape)
    /// cancels the recording under way, and a dictation made before this
    /// hold still pastes.
    @MainActor
    func testHotkeyCancelWhileRecordingCancelsOnlyTheRecording() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.isHeld = true
        let pipeline = makePipeline([apple])
        dictate(clip, on: pipeline)
        try await waitUntil("the earlier dictation reaches the engine") { apple.transcribedClips.count == 1 }

        pipeline.hotkeyDown()
        recorder.nextClip = clip
        pipeline.cancelHold()
        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(pipeline.state, .transcribing)
        apple.isHeld = false
        try await waitUntil("the earlier dictation finishes") { outcomes.count == 1 }

        XCTAssertEqual(outcomes.first?.status, .pasted)
        XCTAssertEqual(paster.pasted, ["hello"])
        XCTAssertEqual(apple.transcribedClips.count, 1, "the cancelled recording reached the engine")
        XCTAssertEqual(pipeline.dictationsInFlight, 0)
    }

    /// When the recorder fails to start, this hold has no dictation, so a key
    /// pressed before Globe is let go cancels nothing: a dictation made
    /// before this hold still pastes.
    @MainActor
    func testHotkeyCancelAfterAFailedStartCancelsNothing() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.isHeld = true
        let pipeline = makePipeline([apple])
        dictate(clip, on: pipeline)
        try await waitUntil("the earlier dictation reaches the engine") { apple.transcribedClips.count == 1 }

        recorder.startFailure = "Microphone in use by another app"
        pipeline.hotkeyDown()
        XCTAssertEqual(pipeline.state, .error("Microphone in use by another app"))
        pipeline.cancelHold()
        apple.isHeld = false
        try await waitUntil("the earlier dictation finishes") { outcomes.count == 1 }

        XCTAssertEqual(outcomes.first?.status, .pasted)
        XCTAssertEqual(paster.pasted, ["hello"])
        XCTAssertEqual(apple.cancelledCount, 0, "the earlier dictation was stopped")
    }

    /// When the recorder ends a recording by itself while Globe stays down
    /// (five minutes, or the input changed), a key pressed before Globe is
    /// let go cancels the dictation that recording became, and only that
    /// one: a dictation made before this hold still pastes.
    @MainActor
    func testHotkeyCancelAfterTheRecorderStopsCancelsOnlyThatDictation() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.isHeld = true
        apple.textForClip = { clip in "clip \(Int(clip.samples[0]))" }
        let (pipeline, service) = makePipelineAndService([apple])
        let clips = (1...2).map(numbered)
        dictate(clips[0], on: pipeline)
        try await waitUntil("the earlier dictation reaches the engine") { apple.transcribedClips == [clips[0]] }

        pipeline.hotkeyDown()
        recorder.nextClip = clips[1]
        recorder.stopRecording()
        try await waitUntil("the stopped recording is in line") { await service.dictationsInLine == 2 }
        pipeline.cancelHold()
        XCTAssertEqual(pipeline.dictationsInFlight, 1, "only the stopped recording leaves the line")
        apple.isHeld = false
        try await waitUntil("the earlier dictation finishes") { outcomes.count == 1 }
        try await waitUntil("the service's line empties") { await service.dictationsInLine == 0 }
        // Time for a stray paste or outcome to show up.
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(paster.pasted, ["clip 1"])
        XCTAssertEqual(outcomes.map(\.status), [.pasted])
        XCTAssertEqual(apple.transcribedClips, [clips[0]], "the cancelled dictation reached the engine")
        XCTAssertEqual(pipeline.dictationsInFlight, 0)
        XCTAssertEqual(pipeline.state, .idle)
    }

    /// Escape while Globe is still held, after the recorder ended the
    /// recording by itself, leaves no trace of that dictation even once the
    /// engine has started on it.
    @MainActor
    func testHotkeyCancelLeavesNoTraceOfARecordingTheRecorderStopped() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.isHeld = true
        let (pipeline, service) = makePipelineAndService([apple])

        pipeline.hotkeyDown()
        recorder.nextClip = clip
        recorder.stopRecording()
        try await waitUntil("the stopped recording reaches the engine") { apple.transcribedClips.count == 1 }
        pipeline.cancelHold()
        XCTAssertEqual(pipeline.dictationsInFlight, 0, "the pipeline still holds the clip")
        XCTAssertEqual(pipeline.state, .idle)
        try await waitUntil("the engine stops") { apple.cancelledCount == 1 }
        try await waitUntil("the service's line empties") { await service.dictationsInLine == 0 }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(paster.pasted, [])
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertEqual(pipeline.state, .idle)
    }

    /// The first press can wait on the microphone prompt. A key released
    /// before the recorder starts leaves nothing behind, and a recording the
    /// recorder starts by itself afterwards is cancelled at once.
    @MainActor
    func testRecordingThatStartsAfterTheKeyIsUpIsCancelled() {
        let pipeline = makePipeline([FakeEngine(kind: .appleSpeech)])
        recorder.startsLater = true

        pipeline.hotkeyDown()
        XCTAssertEqual(pipeline.state, .idle)
        pipeline.hotkeyUp()
        XCTAssertEqual(pipeline.dictationsInFlight, 0)
        recorder.startNow()

        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertTrue(outcomes.isEmpty)
    }

    // MARK: - State

    /// After an error the state returns to the true one, which with a
    /// permission missing is `.needsPermission`, not `.idle`.
    @MainActor
    func testErrorStateReturnsToTrueState() async throws {
        let pipeline = makePipeline([FakeEngine(kind: .appleSpeech)])
        pipeline.errorDisplaySeconds = 0.1
        pipeline.missingPermission = "Microphone"
        XCTAssertEqual(pipeline.state, .needsPermission("Microphone"))

        recorder.startFailure = "Microphone access denied"
        pipeline.hotkeyDown()
        XCTAssertEqual(pipeline.state, .error("Microphone access denied"))
        try await waitUntil("the error clears") { pipeline.state != .error("Microphone access denied") }

        XCTAssertEqual(pipeline.state, .needsPermission("Microphone"))
        XCTAssertTrue(outcomes.isEmpty, "a recording that never started is not a dictation")
        pipeline.missingPermission = nil
        XCTAssertEqual(pipeline.state, .idle)
    }

    /// The work under way, which the hotkey's tap and the indicator read
    /// (final fix wave, item A): recording, then a cleanup
    /// (`CleanupPipelineTests`), then dictations in line, else idle. An error
    /// on show, a model being prepared and a missing permission are in
    /// `state` only, for the menu bar.
    @MainActor
    func testTheWorkUnderWayIsReadPastAnError() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.isHeld = true
        let pipeline = makePipeline([apple])
        pipeline.errorDisplaySeconds = 60
        pipeline.missingPermission = "Accessibility"
        XCTAssertEqual(pipeline.state, .needsPermission("Accessibility"))
        XCTAssertEqual(pipeline.work, .idle)

        dictate(clip, on: pipeline)
        try await waitUntil("the dictation reaches the engine") { apple.transcribedClips.count == 1 }
        XCTAssertEqual(pipeline.work, .transcribing)
        recorder.startFailure = "Microphone in use by another app"
        pipeline.hotkeyDown()
        XCTAssertEqual(pipeline.state, .error("Microphone in use by another app"))
        XCTAssertEqual(pipeline.work, .transcribing, "the dictation in line is still under way")

        recorder.startFailure = nil
        pipeline.hotkeyDown()
        guard case .recording = pipeline.work else { return XCTFail("not recording: \(pipeline.work)") }
        XCTAssertEqual(pipeline.state, pipeline.work, "recording comes first in both")
        pipeline.cancel()
        XCTAssertEqual(pipeline.work, .transcribing)

        apple.isHeld = false
        try await waitUntil("the dictation finishes") { outcomes.count == 1 }
        XCTAssertEqual(pipeline.work, .idle)
        await pipeline.whilePreparing("WhisperKit base.en") {
            XCTAssertEqual(pipeline.state, .preparingModel("WhisperKit base.en"))
            XCTAssertEqual(pipeline.work, .idle)
        }
    }

    /// Each slice's peak goes on with the time it was captured, every one of
    /// a burst, while recording; none after (Task 24A).
    @MainActor
    func testLevelFollowsTheRecording() {
        let pipeline = makePipeline([FakeEngine(kind: .appleSpeech)])
        var heard: [(peak: Float, at: TimeInterval)] = []
        pipeline.onLevel = { heard.append(($0, $1)) }

        pipeline.hotkeyDown()
        recorder.onLevel?(0.4, 100)
        recorder.onLevel?(0.2, 100.05)
        XCTAssertEqual(heard.map { $0.peak }, [0.4, 0.2])
        XCTAssertEqual(heard.map { $0.at }, [100, 100.05])
        pipeline.cancel()
        recorder.onLevel?(0.7, 100.1)
        XCTAssertEqual(heard.count, 2, "a level that arrives after the recording")
    }

    /// Choosing a model shows `.preparingModel` while it downloads and loads.
    @MainActor
    func testSelectModelShowsPreparingModelMeanwhile() async throws {
        let whisper = FakeEngine(kind: .whisperKit)
        whisper.isPrepareHeld = true
        let (pipeline, service) = makePipelineAndService([FakeEngine(kind: .appleSpeech), whisper])

        let choosing = Task { try await pipeline.selectModel(whisperBase, named: "WhisperKit base.en", downloadingFirst: true) }
        try await waitUntil("the model is preparing") { whisper.calls.contains(.prepare(whisperBase)) }
        XCTAssertEqual(pipeline.state, .preparingModel("WhisperKit base.en"))
        whisper.isPrepareHeld = false
        try await waitUntil("the model is chosen") { pipeline.state == .idle }
        try await choosing.value

        XCTAssertEqual(pipeline.state, .idle)
        let selected = await service.selected
        XCTAssertEqual(selected, whisperBase)
        XCTAssertEqual(Array(whisper.calls.prefix(2)), [.download(whisperBase), .prepare(whisperBase)])
    }

    @MainActor
    func testFailedModelChoiceShowsTheErrorAndKeepsTheSelection() async throws {
        let whisper = FakeEngine(kind: .whisperKit)
        whisper.prepareError = TranscriptionError.modelNotReady("WhisperKit base.en is not downloaded")
        let (pipeline, service) = makePipelineAndService([FakeEngine(kind: .appleSpeech), whisper])
        pipeline.errorDisplaySeconds = 0.5

        do {
            try await pipeline.selectModel(whisperBase, named: "WhisperKit base.en")
            XCTFail("chose a model that cannot load")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .modelNotReady("WhisperKit base.en is not downloaded"))
        }

        XCTAssertEqual(pipeline.state, .error("WhisperKit base.en is not downloaded"))
        let selected = await service.selected
        XCTAssertEqual(selected, .appleSpeech)
        try await waitUntil("the error clears") { pipeline.state == .idle }
    }

    // MARK: - Timing (Ruling P5)

    /// Each dictation carries its own marks through the line, so the summary
    /// logged after its paste has all three intervals.
    @MainActor
    func testTimingMarksEachStage() async throws {
        let pipeline = makePipeline([FakeEngine(kind: .appleSpeech)])

        pipeline.hotkeyDown()
        recorder.onFirstAudio?(Date())
        recorder.nextClip = clip
        pipeline.hotkeyUp()
        try await waitUntil("the dictation finishes") { outcomes.count == 1 }

        let timing = try XCTUnwrap(pipeline.lastTiming)
        XCTAssertNotNil(timing.milliseconds(from: .keyDown, to: .firstAudio))
        XCTAssertNotNil(timing.milliseconds(from: .keyUp, to: .textReady))
        XCTAssertNotNil(timing.milliseconds(from: .textReady, to: .pasted))
        XCTAssertEqual(timing.summary.split(separator: " ").count, 3, timing.summary)
    }

    /// A recording the recorder ends by itself (five minutes, or the input
    /// changed) has no key-up, so its time to text runs from when it ended.
    /// One too short to deliver audio leaves the first interval out.
    @MainActor
    func testRecordingTheRecorderEndsIsTimedFromItsEnd() async throws {
        let pipeline = makePipeline([FakeEngine(kind: .appleSpeech)])

        pipeline.hotkeyDown()
        recorder.nextClip = clip
        recorder.stopRecording()
        try await waitUntil("the dictation finishes") { outcomes.count == 1 }
        pipeline.hotkeyUp()

        let timing = try XCTUnwrap(pipeline.lastTiming)
        XCTAssertNotNil(timing.milliseconds(from: .keyUp, to: .textReady))
        XCTAssertNil(timing.milliseconds(from: .keyDown, to: .firstAudio))
        XCTAssertFalse(timing.summary.contains("firstAudio"), timing.summary)
        XCTAssertEqual(recorder.startCount, 1, "the late key-up started nothing")
        XCTAssertEqual(pipeline.state, .idle)
    }

    // MARK: - Paste last (Ruling P4)

    /// Paste last pastes what its source says is the latest text, which the
    /// app points at the store's latest transcript, so an edit made in the
    /// window is what pastes. The pipeline keeps no text of its own: a
    /// dictation it just pasted changes nothing until the source has it.
    /// With no text there is nothing to paste, and the menu item is off.
    @MainActor
    func testPasteLastPastesTheLatestTextItIsGiven() async throws {
        var latest: String?
        let pipeline = makePipeline([FakeEngine(kind: .appleSpeech)], latestText: { latest })
        XCTAssertFalse(pipeline.canPasteLast)
        pipeline.pasteLast()
        XCTAssertEqual(paster.pasted, [], "nothing to paste")

        latest = "Edited in the window."
        XCTAssertTrue(pipeline.canPasteLast)
        pipeline.pasteLast()
        XCTAssertEqual(paster.pasted, ["Edited in the window."])

        dictate(clip, on: pipeline)
        try await waitUntil("the dictation finishes") { outcomes.count == 1 }
        pipeline.pasteLast()

        XCTAssertEqual(paster.pasted, ["Edited in the window.", "hello", "Edited in the window."])
        XCTAssertEqual(outcomes.count, 1, "pasting again is not a dictation")
        latest = ""
        XCTAssertFalse(pipeline.canPasteLast, "an empty text is nothing to paste")
    }

    // MARK: - A tap with double-tap dictation on (Task 23)

    /// A tap is no dictation: the recording the press started is thrown
    /// away and leaves no trace, and a dictation made before it still pastes.
    @MainActor
    func testDiscardTapThrowsTheRecordingAwayAndNothingElse() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.isHeld = true
        let pipeline = makePipeline([apple])
        dictate(clip, on: pipeline)
        try await waitUntil("the earlier dictation reaches the engine") { apple.transcribedClips.count == 1 }

        pipeline.hotkeyDown()
        recorder.nextClip = clip
        pipeline.discardTap()
        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(pipeline.state, .transcribing)
        apple.isHeld = false
        try await waitUntil("the earlier dictation finishes") { outcomes.count == 1 }

        XCTAssertEqual(paster.pasted, ["hello"])
        XCTAssertEqual(apple.transcribedClips.count, 1, "the tap's recording reached the engine")
        XCTAssertEqual(pipeline.dictationsInFlight, 0)
        XCTAssertEqual(pipeline.state, .idle)
    }

    // MARK: - Helpers

    @MainActor
    private func makePipeline(_ engines: [FakeEngine], selected: ModelID = .appleSpeech,
                              latestText: @escaping () -> String? = { nil }) -> DictationPipeline {
        makePipelineAndService(engines, selected: selected, latestText: latestText).pipeline
    }

    @MainActor
    private func makePipelineAndService(_ engines: [FakeEngine], selected: ModelID = .appleSpeech,
                                        latestText: @escaping () -> String? = { nil })
        -> (pipeline: DictationPipeline, service: TranscriptionService) {
        let service = TranscriptionService(engines: engines, selected: selected)
        let pipeline = DictationPipeline(recorder: recorder, service: service, paster: paster,
                                         cleaner: nil, replacements: { [] }, vocabulary: { [] },
                                         latestText: latestText)
        pipeline.onOutcome = { [weak self] outcome in self?.outcomes.append(outcome) }
        return (pipeline, service)
    }

    /// Holds the hotkey while the recorder captures `clip`, then lets go.
    @MainActor
    private func dictate(_ clip: AudioClip, on pipeline: DictationPipeline) {
        pipeline.hotkeyDown()
        recorder.nextClip = clip
        pipeline.hotkeyUp()
    }

    /// A clip the fake engine can tell apart: its first sample is `number`.
    private func numbered(_ number: Int) -> AudioClip {
        AudioClip(samples: [Float(number)] + [Float](repeating: 0.2, count: 16_000))
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
