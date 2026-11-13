import XCTest
@testable import VoiceDictationLib

final class TranscriptionServiceTests: XCTestCase {
    private let whisperBase = ModelID(engine: .whisperKit, name: "base.en")
    private let whisperTiny = ModelID(engine: .whisperKit, name: "tiny.en")
    private let cliBase = ModelID(engine: .whisperCLI, name: "base.en")
    private let clip = AudioClip(samples: [Float](repeating: 0.2, count: 16_000))

    // MARK: - Results

    func testResultCarriesModelAndElapsed() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.result = "Hello there."
        apple.delay = 0.2
        apple.prepareDelay = 0.3
        let service = TranscriptionService(engines: [apple], selected: .appleSpeech)

        let result = try await service.transcribe(clip, vocabulary: [])

        XCTAssertEqual(result.text, "Hello there.")
        XCTAssertEqual(result.model, .appleSpeech)
        XCTAssertGreaterThanOrEqual(result.elapsed, 0.2)
        XCTAssertLessThan(result.elapsed, 0.5, "counts the transcription only, not preparing the model")
    }

    /// Ruling P3: the service filters every engine's text, in both lanes.
    func testOutputFilterApplied() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.result = "Thank you."
        let whisper = FakeEngine(kind: .whisperKit)
        whisper.result = "Thank you."
        let service = TranscriptionService(engines: [apple, whisper], selected: .appleSpeech)

        let dictation = try await service.transcribe(clip, vocabulary: [])
        let retranscription = try await service.transcribe(clip, with: whisperBase, vocabulary: [])

        XCTAssertEqual(dictation.text, "")
        XCTAssertEqual(retranscription.text, "")
    }

    // MARK: - Dictations

    /// Review Focus 4: dictations finish in the order they were made.
    func testSerialOrder() async throws {
        let probe = ConcurrencyProbe()
        let apple = FakeEngine(kind: .appleSpeech, probe: probe)
        apple.delay = 0.05
        apple.isHeld = true
        let service = TranscriptionService(engines: [apple], selected: .appleSpeech)
        let finished = Order<String>()

        var dictations: [Task<TranscriptionResult, Error>] = []
        for number in 1...3 {
            dictations.append(dictation(on: service, recordingIn: finished, as: "dictation \(number)"))
            try await waitUntil("dictation \(number) is in line") { await service.dictationsInLine == number }
        }
        apple.isHeld = false
        for task in dictations { _ = try await finish(task, within: 2, "a dictation") }

        XCTAssertEqual(finished.values, ["dictation 1", "dictation 2", "dictation 3"])
        XCTAssertEqual(probe.maxRunning, 1)
    }

    /// Review Focus 1: a dictation made while the model loads waits for that
    /// load instead of starting a second one, then succeeds.
    func testWaitsForPrepareInFlight() async throws {
        let log = CallLog()
        let apple = FakeEngine(kind: .appleSpeech, log: log)
        // Held until the dictation is in line, then it sleeps 200 ms.
        apple.isPrepareHeld = true
        apple.prepareDelay = 0.2
        let service = TranscriptionService(engines: [apple], selected: .appleSpeech)
        let preparing = Task { await service.prepareSelected() }
        try await waitUntil("Apple Speech is preparing") { apple.calls.contains(.prepare(.appleSpeech)) }

        let dictation = Task { try await service.transcribe(clip, vocabulary: []) }
        try await waitUntil("the dictation is in line") { await service.dictationsInLine == 1 }
        apple.isPrepareHeld = false
        let result = try await finish(dictation, within: 2, "the dictation")

        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(log.entries, [.call(.appleSpeech, .prepare(.appleSpeech)), .prepared(.appleSpeech),
                                     .call(.appleSpeech, .transcribe(.appleSpeech))],
                       "transcribed before the model was ready, or did not join the prepare in flight")
        await preparing.value
    }

    func testPrepareFailureSurfacesAsModelNotReady() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.prepareError = TranscriptionError.failed("Core ML could not compile the model")
        let service = TranscriptionService(engines: [apple], selected: .appleSpeech)
        let expected = TranscriptionError.modelNotReady("Core ML could not compile the model")

        await service.prepareSelected()
        let kept = await service.prepareFailure(of: .appleSpeech)
        XCTAssertEqual(kept, expected, "prepareSelected keeps its error")

        do {
            _ = try await service.transcribe(clip, vocabulary: [])
            XCTFail("transcribed with a model that failed to load")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, expected)
        }
        XCTAssertFalse(apple.calls.contains(.transcribe(.appleSpeech)))

        // Once the model can load, the next dictation loads it and goes ahead.
        apple.prepareError = nil
        let result = try await service.transcribe(clip, vocabulary: [])
        XCTAssertEqual(result.text, "hello")
        let cleared = await service.prepareFailure(of: .appleSpeech)
        XCTAssertNil(cleared)
    }

    /// A selection no engine runs, such as a model of the retired whisper-cli:
    /// `prepareSelected` keeps that, as for any failure.
    func testPrepareSelectedKeepsAMissingEngine() async {
        let service = TranscriptionService(engines: [FakeEngine(kind: .appleSpeech)], selected: cliBase)

        await service.prepareSelected()

        let kept = await service.prepareFailure(of: cliBase)
        XCTAssertEqual(kept, .engineUnavailable("No engine runs whisperCLI/base.en"))
    }

    func testCancelledDictationLeavesTheLine() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.isHeld = true
        let service = TranscriptionService(engines: [apple], selected: .appleSpeech)
        let first = Task { try await service.transcribe(clip, vocabulary: []) }
        try await waitUntil("the first dictation is transcribing") { apple.calls.contains(.transcribe(.appleSpeech)) }
        let second = Task { try await service.transcribe(clip, vocabulary: []) }
        try await waitUntil("the second dictation is waiting") { await service.dictationsInLine == 2 }

        second.cancel()

        await assertCancelled(second, within: 0.5)
        let inLine = await service.dictationsInLine
        XCTAssertEqual(inLine, 1)
        apple.isHeld = false
        _ = try await finish(first, within: 2, "the first dictation")
        XCTAssertEqual(transcriptions(apple), [.appleSpeech], "the cancelled dictation reached the engine")
    }

    /// A dictation cancelled while its model loads stops waiting at once; the
    /// load carries on, and the next dictation uses it.
    func testCancelledDictationStopsWaitingForItsModel() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.prepareDelay = 0.5
        let service = TranscriptionService(engines: [apple], selected: .appleSpeech)
        let waiting = Task { try await service.transcribe(clip, vocabulary: []) }
        try await waitUntil("Apple Speech is preparing") { apple.calls.contains(.prepare(.appleSpeech)) }

        waiting.cancel()

        await assertCancelled(waiting, within: 0.2)
        _ = try await finish(Task { try await service.transcribe(clip, vocabulary: []) }, within: 2, "the next dictation")
        XCTAssertEqual(apple.calls, [.prepare(.appleSpeech), .transcribe(.appleSpeech)])
    }

    // MARK: - Choosing and deleting models

    /// One log shared by both fakes shows the order across the engines.
    func testSelectLoadsNewBeforeUnloadingOld() async throws {
        let log = CallLog()
        let apple = FakeEngine(kind: .appleSpeech, log: log)
        let whisper = FakeEngine(kind: .whisperKit, log: log)
        whisper.isPrepareHeld = true
        let service = TranscriptionService(engines: [apple, whisper], selected: .appleSpeech)
        await service.prepareSelected()

        let selecting = Task { try await service.select(whisperBase) }
        try await waitUntil("base.en is preparing") { whisper.calls.contains(.prepare(whisperBase)) }
        let during = await service.selected
        XCTAssertEqual(during, .appleSpeech, "switched before the new model was ready")
        whisper.isPrepareHeld = false
        try await finish(selecting, within: 2, "select")
        // The unload runs in a task of its own.
        try await waitUntil("Apple Speech is unloaded") { apple.calls.contains(.unload) }

        XCTAssertEqual(log.entries, [.call(.appleSpeech, .prepare(.appleSpeech)), .prepared(.appleSpeech),
                                     .call(.whisperKit, .prepare(whisperBase)), .prepared(whisperBase),
                                     .call(.appleSpeech, .unload)],
                       "unloaded the old engine before the new model was ready")
        let selected = await service.selected
        XCTAssertEqual(selected, whisperBase)
    }

    /// `select` calls take effect one at a time, in call order, so the last
    /// one made wins, even over an earlier one that is slower to prepare.
    func testConcurrentSelectsEndOnTheLastOne() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        let whisper = FakeEngine(kind: .whisperKit)
        whisper.isPrepareHeld = true
        let service = TranscriptionService(engines: [apple, whisper], selected: .appleSpeech)

        var selects = [Task { try await service.select(whisperBase) }]
        try await waitUntil("base.en is preparing") { whisper.calls.contains(.prepare(whisperBase)) }
        for (number, id) in [(2, whisperTiny), (3, ModelID.appleDictation)] {
            selects.append(Task { try await service.select(id) })
            try await waitUntil("select \(number) is in line") { await service.selectionsInLine == number }
        }
        whisper.isPrepareHeld = false
        for task in selects { try await finish(task, within: 2, "a select") }

        let selected = await service.selected
        XCTAssertEqual(selected, .appleDictation)
    }

    func testFailedSelectKeepsTheOldModel() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        let whisper = FakeEngine(kind: .whisperKit)
        whisper.prepareError = TranscriptionError.modelNotReady("WhisperKit base.en is not downloaded")
        let service = TranscriptionService(engines: [apple, whisper], selected: .appleSpeech)
        await service.prepareSelected()

        do {
            try await service.select(whisperBase)
            XCTFail("selected a model that could not load")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .modelNotReady("WhisperKit base.en is not downloaded"))
        }

        let selected = await service.selected
        XCTAssertEqual(selected, .appleSpeech)
        XCTAssertEqual(apple.calls, [.prepare(.appleSpeech)], "unloaded the model still in use")
    }

    /// Ruling T8-1: an engine a dictation is still using is not unloaded
    /// when another model is chosen; it goes once the dictation is done.
    func testSelectDoesNotUnloadAnEngineInUse() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.isHeld = true
        let whisper = FakeEngine(kind: .whisperKit)
        let service = TranscriptionService(engines: [apple, whisper], selected: .appleSpeech, idleUnloadDelay: 0.1)
        let dictation = Task { try await service.transcribe(clip, vocabulary: []) }
        try await waitUntil("the dictation is transcribing") { apple.calls.contains(.transcribe(.appleSpeech)) }

        try await service.select(whisperBase)

        XCTAssertFalse(apple.calls.contains(.unload), "unloaded an engine a dictation was using")
        apple.isHeld = false
        let result = try await finish(dictation, within: 2, "the dictation")
        XCTAssertEqual(result.model, .appleSpeech, "the dictation kept the model it started with")
        try await waitUntil("Apple Speech is unloaded once the dictation is done") { apple.calls.contains(.unload) }
        XCTAssertFalse(whisper.calls.contains(.unload), "unloaded the selected model")
    }

    func testDeleteSelectedRefused() async throws {
        let whisper = FakeEngine(kind: .whisperKit)
        let service = TranscriptionService(engines: [FakeEngine(kind: .appleSpeech), whisper], selected: whisperBase)

        do {
            try await service.delete(whisperBase)
            XCTFail("deleted the selected model")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .failed("The model used for dictation cannot be deleted"))
        }
        try await service.delete(whisperTiny)

        XCTAssertEqual(whisper.calls, [.delete(whisperTiny)])
    }

    func testAllModelsAndDownloadsGoToEachEngine() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.modelList = [descriptor(.appleSpeech), descriptor(.appleDictation)]
        let whisper = FakeEngine(kind: .whisperKit)
        whisper.modelList = [descriptor(whisperTiny), descriptor(whisperBase)]
        let service = TranscriptionService(engines: [apple, whisper], selected: .appleSpeech)

        let ids = await service.allModels().map(\.id)
        let progress = Order<Double>()
        try await service.download(whisperBase) { progress.append($0) }

        XCTAssertEqual(ids, [.appleSpeech, .appleDictation, whisperTiny, whisperBase])
        XCTAssertEqual(whisper.calls, [.download(whisperBase)])
        XCTAssertEqual(progress.values, [1])
        XCTAssertEqual(apple.calls, [])
    }

    // MARK: - Re-transcriptions

    func testRetranscribeDoesNotChangeSelection() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        apple.result = "From Apple."
        let whisper = FakeEngine(kind: .whisperKit)
        whisper.result = "From WhisperKit."
        let service = TranscriptionService(engines: [apple, whisper], selected: .appleSpeech)
        await service.prepareSelected()

        let result = try await service.transcribe(clip, with: whisperBase, vocabulary: [])

        XCTAssertEqual(result.text, "From WhisperKit.")
        XCTAssertEqual(result.model, whisperBase)
        let selected = await service.selected
        XCTAssertEqual(selected, .appleSpeech)
        XCTAssertEqual(apple.calls, [.prepare(.appleSpeech)], "touched the selected model's engine")
        let dictation = try await service.transcribe(clip, vocabulary: [])
        XCTAssertEqual(dictation.model, .appleSpeech)
        XCTAssertEqual(dictation.text, "From Apple.")
    }

    /// Review Focus 4: a dictation stops a re-transcription, goes first, and
    /// the re-transcription runs again from the start by itself.
    func testDictationPreemptsRetranscription() async throws {
        let probe = ConcurrencyProbe()
        let apple = FakeEngine(kind: .appleSpeech, probe: probe)
        apple.delay = 0.05
        apple.result = "Dictated."
        let whisper = FakeEngine(kind: .whisperKit, probe: probe)
        whisper.delay = 2
        whisper.result = "Re-transcribed."
        let service = TranscriptionService(engines: [apple, whisper], selected: .appleSpeech)
        await service.prepareSelected()

        let issued = ContinuousClock.now
        let retranscription = Task { try await service.transcribe(clip, with: whisperBase, vocabulary: []) }
        try await waitUntil("the re-transcription is transcribing") { whisper.calls.contains(.transcribe(whisperBase)) }
        try await Task.sleep(until: issued + .milliseconds(100), clock: .continuous)
        let dictationIssued = ContinuousClock.now
        let dictation = try await finish(Task { try await service.transcribe(clip, vocabulary: []) },
                                         within: 2, "the dictation")
        let dictationTook = dictationIssued.duration(to: .now)

        XCTAssertLessThan(dictationTook, .milliseconds(500))
        XCTAssertEqual(dictation.text, "Dictated.")
        let result = try await finish(retranscription, within: 5, "the re-transcription")
        XCTAssertEqual(result.text, "Re-transcribed.")
        XCTAssertEqual(result.model, whisperBase)
        XCTAssertEqual(whisper.cancelledCount, 1)
        XCTAssertEqual(transcriptions(whisper), [whisperBase, whisperBase], "ran again from the start")
        XCTAssertEqual(probe.maxRunning, 1)
    }

    /// Review Focus 4: a re-transcription waits for every dictation already in line.
    func testRetranscriptionWaitsForQueuedDictations() async throws {
        let probe = ConcurrencyProbe()
        let apple = FakeEngine(kind: .appleSpeech, probe: probe)
        apple.delay = 0.05
        apple.isHeld = true
        let service = TranscriptionService(engines: [apple], selected: .appleSpeech)
        let finished = Order<String>()

        var dictations: [Task<TranscriptionResult, Error>] = []
        for number in 1...3 {
            dictations.append(dictation(on: service, recordingIn: finished, as: "dictation \(number)"))
            try await waitUntil("dictation \(number) is in line") { await service.dictationsInLine == number }
        }
        let retranscription = Task {
            let result = try await service.transcribe(clip, with: .appleDictation, vocabulary: [])
            finished.append("re-transcription")
            return result
        }
        try await waitUntil("the re-transcription has prepared its model") {
            apple.calls.contains(.prepare(.appleDictation))
        }
        XCTAssertEqual(transcriptions(apple), [.appleSpeech], "only the first dictation has started")
        apple.isHeld = false
        for task in dictations { _ = try await finish(task, within: 2, "a dictation") }
        let result = try await finish(retranscription, within: 2, "the re-transcription")

        XCTAssertEqual(result.model, .appleDictation)
        XCTAssertEqual(finished.values, ["dictation 1", "dictation 2", "dictation 3", "re-transcription"])
        XCTAssertEqual(transcriptions(apple), [.appleSpeech, .appleSpeech, .appleSpeech, .appleDictation])
        XCTAssertEqual(probe.maxRunning, 1)
    }

    /// Review Focus 4: loading a model for a re-transcription never holds up a dictation.
    func testDictationDoesNotWaitForRetranscriptionLoad() async throws {
        let probe = ConcurrencyProbe()
        let apple = FakeEngine(kind: .appleSpeech, probe: probe)
        apple.delay = 0.05
        let whisper = FakeEngine(kind: .whisperKit, probe: probe)
        whisper.prepareDelay = 2
        let service = TranscriptionService(engines: [apple, whisper], selected: .appleSpeech)
        await service.prepareSelected()

        let retranscription = Task { try await service.transcribe(clip, with: whisperBase, vocabulary: []) }
        try await waitUntil("base.en is loading") { whisper.calls.contains(.prepare(whisperBase)) }
        let dictationIssued = ContinuousClock.now
        let dictation = try await finish(Task { try await service.transcribe(clip, vocabulary: []) },
                                         within: 3, "the dictation")
        let dictationTook = dictationIssued.duration(to: .now)

        XCTAssertLessThan(dictationTook, .milliseconds(500))
        XCTAssertEqual(dictation.model, .appleSpeech)
        let stillWaiting = await service.retranscriptionsInLine
        XCTAssertEqual(stillWaiting, 1, "the re-transcription finished before its model loaded")
        let result = try await finish(retranscription, within: 5, "the re-transcription")
        XCTAssertEqual(result.model, whisperBase)
        XCTAssertEqual(probe.maxRunning, 1)
    }

    /// Review Focus 4: one probe across a load, two preemptions, queued
    /// dictations and a queued re-transcription never sees two at once.
    func testNeverTwoTranscriptionsAtOnce() async throws {
        let probe = ConcurrencyProbe()
        let apple = FakeEngine(kind: .appleSpeech, probe: probe)
        apple.delay = 0.05
        let whisper = FakeEngine(kind: .whisperKit, probe: probe)
        // Held, so each dictation below arrives while base.en loads or
        // transcribes, however slowly this test runs.
        whisper.isPrepareHeld = true
        whisper.isHeld = true
        whisper.result = "Re-transcribed."
        let service = TranscriptionService(engines: [apple, whisper], selected: .appleSpeech)
        await service.prepareSelected()
        var dictations: [Task<TranscriptionResult, Error>] = []

        // A dictation while the re-transcription's model loads.
        let first = Task { try await service.transcribe(clip, with: whisperBase, vocabulary: []) }
        try await waitUntil("base.en is loading") { whisper.calls.contains(.prepare(whisperBase)) }
        _ = try await finish(Task { try await service.transcribe(clip, vocabulary: []) }, within: 1, "dictation 1")
        whisper.isPrepareHeld = false

        // Two dictations while it transcribes, and a second re-transcription behind it.
        try await waitUntil("the re-transcription is transcribing") { whisper.calls.contains(.transcribe(whisperBase)) }
        apple.isHeld = true
        dictations.append(Task { try await service.transcribe(clip, vocabulary: []) })
        try await waitUntil("dictation 2 has stopped the re-transcription") { self.transcriptions(apple).count == 2 }
        dictations.append(Task { try await service.transcribe(clip, vocabulary: []) })
        let second = Task { try await service.transcribe(clip, with: .appleDictation, vocabulary: []) }
        try await waitUntil("dictation 3 and the second re-transcription are in line") {
            let dictations = await service.dictationsInLine
            let retranscriptions = await service.retranscriptionsInLine
            return dictations == 2 && retranscriptions == 2
        }
        XCTAssertEqual(probe.maxRunning, 1)
        apple.isHeld = false

        // One more dictation once the first re-transcription has started again.
        try await waitUntil("the re-transcription runs again") { self.transcriptions(whisper).count == 2 }
        dictations.append(Task { try await service.transcribe(clip, vocabulary: []) })
        try await waitUntil("dictation 4 has stopped it again") { whisper.cancelledCount == 2 }
        whisper.isHeld = false

        for task in dictations {
            let result = try await finish(task, within: 3, "a dictation")
            XCTAssertEqual(result.model, .appleSpeech)
        }
        let firstResult = try await finish(first, within: 5, "the first re-transcription")
        let secondResult = try await finish(second, within: 5, "the second re-transcription")
        XCTAssertEqual(firstResult.text, "Re-transcribed.")
        XCTAssertEqual(secondResult.model, .appleDictation)
        XCTAssertEqual(whisper.cancelledCount, 2)
        XCTAssertEqual(probe.maxRunning, 1)
    }

    /// A caller that cancels its own re-transcription gets `CancellationError`,
    /// whether it was transcribing or waiting its turn, and it is not run again.
    func testCancelledRetranscriptionThrowsCancellationError() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        let whisper = FakeEngine(kind: .whisperKit)
        whisper.delay = 2
        let service = TranscriptionService(engines: [apple, whisper], selected: .appleSpeech)
        let running = Task { try await service.transcribe(clip, with: whisperBase, vocabulary: []) }
        try await waitUntil("the re-transcription is transcribing") { whisper.calls.contains(.transcribe(whisperBase)) }
        let waiting = Task { try await service.transcribe(clip, with: whisperTiny, vocabulary: []) }
        try await waitUntil("the second re-transcription is in line") { await service.retranscriptionsInLine == 2 }

        waiting.cancel()
        await assertCancelled(waiting, within: 0.5)
        running.cancel()
        await assertCancelled(running, within: 0.5)

        XCTAssertEqual(whisper.cancelledCount, 1)
        XCTAssertEqual(transcriptions(whisper), [whisperBase], "ran again after its caller cancelled")
        let inLine = await service.retranscriptionsInLine
        XCTAssertEqual(inLine, 0)
        let next = try await finish(Task { try await service.transcribe(clip, vocabulary: []) }, within: 1, "a dictation")
        XCTAssertEqual(next.model, .appleSpeech)
    }

    /// Rulings T8-1 and T8-2: a model loaded only for re-transcriptions is
    /// unloaded `idleUnloadDelay` after the re-transcription lane empties,
    /// not before. The selected model's engine never is, even when a
    /// re-transcription loaded another model on it.
    ///
    /// The delay is real, so a test that stalls for 0.1 s can rightly see an
    /// unload sooner than planned. Every check below holds however slowly the
    /// test runs: times are measured from before the calls, the wait is for
    /// the unload after the last use, and the calls after it are compared as
    /// a prefix, which a late `.unload` cannot change.
    func testRetranscriptionOnlyModelUnloadedAfterIdleDelay() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        let whisper = FakeEngine(kind: .whisperKit)
        let delay = Duration.milliseconds(100)
        let service = TranscriptionService(engines: [apple, whisper], selected: .appleSpeech, idleUnloadDelay: 0.1)
        await service.prepareSelected()

        let firstUse = ContinuousClock.now
        _ = try await service.transcribe(clip, with: whisperBase, vocabulary: [])
        _ = try await service.transcribe(clip, with: whisperBase, vocabulary: [])
        // Back to back, the model stays loaded: no unload or second prepare
        // in between. Only a stall of the whole delay could rightly unload
        // it, so the check needs the two calls to take less than that.
        let backToBack = whisper.calls
        if firstUse.duration(to: .now) < delay {
            XCTAssertEqual(backToBack, [.prepare(whisperBase), .transcribe(whisperBase), .transcribe(whisperBase)])
        }
        _ = try await service.transcribe(clip, with: .appleDictation, vocabulary: [])

        try await waitUntil("WhisperKit is unloaded") { whisper.calls.last == .unload }
        XCTAssertGreaterThanOrEqual(firstUse.duration(to: .now), delay, "unloaded before the delay")
        let unloads = whisper.calls.filter { $0 == .unload }.count
        try await Task.sleep(for: delay * 3)
        XCTAssertFalse(apple.calls.contains(.unload), "unloaded the engine of the selected model")
        XCTAssertEqual(whisper.calls.filter { $0 == .unload }.count, unloads, "unloaded again with nothing loaded")

        // Once unloaded, the model is prepared again before it is used.
        let before = whisper.calls.count
        _ = try await service.transcribe(clip, with: whisperBase, vocabulary: [])
        XCTAssertEqual(Array(whisper.calls.dropFirst(before).prefix(2)), [.prepare(whisperBase), .transcribe(whisperBase)])
    }

    /// Ruling T8-2: while re-transcriptions keep the lane busy, every engine
    /// they use stays loaded, even one left unused for longer than the
    /// delay while another engine works. Both go `idleUnloadDelay` after the
    /// lane empties. Each re-transcription is held until the next one is in
    /// line, so the lane never empties in between.
    func testIdleUnloadWaitsForTheRetranscriptionLaneToEmpty() async throws {
        let apple = FakeEngine(kind: .appleSpeech)
        let whisper = FakeEngine(kind: .whisperKit)
        let cpp = FakeEngine(kind: .whisperCpp)
        let cppBase = ModelID.whisperCppBase
        whisper.isHeld = true
        cpp.isHeld = true
        let delay = Duration.milliseconds(100)
        let service = TranscriptionService(engines: [apple, whisper, cpp], selected: .appleSpeech, idleUnloadDelay: 0.1)
        await service.prepareSelected()
        var retranscriptions: [Task<TranscriptionResult, Error>] = []

        // WhisperKit, then whisper.cpp, which keeps the lane while WhisperKit sits unused.
        retranscriptions.append(Task { try await service.transcribe(clip, with: whisperBase, vocabulary: []) })
        try await waitUntil("WhisperKit transcribes") { self.transcriptions(whisper).count == 1 }
        retranscriptions.append(Task { try await service.transcribe(clip, with: cppBase, vocabulary: []) })
        try await waitUntil("the whisper.cpp re-transcription is in line") { await service.retranscriptionsInLine == 2 }
        whisper.isHeld = false
        try await waitUntil("whisper.cpp transcribes") { self.transcriptions(cpp).count == 1 }
        try await Task.sleep(for: delay * 3)

        // WhisperKit again, which keeps the lane while whisper.cpp sits unused.
        whisper.isHeld = true
        retranscriptions.append(Task { try await service.transcribe(clip, with: whisperBase, vocabulary: []) })
        try await waitUntil("WhisperKit is in line again") { await service.retranscriptionsInLine == 2 }
        cpp.isHeld = false
        try await waitUntil("WhisperKit transcribes again") { self.transcriptions(whisper).count == 2 }
        try await Task.sleep(for: delay * 3)

        XCTAssertEqual(whisper.calls, [.prepare(whisperBase), .transcribe(whisperBase), .transcribe(whisperBase)],
                       "unloaded while the lane was busy")
        XCTAssertEqual(cpp.calls, [.prepare(cppBase), .transcribe(cppBase)], "unloaded while the lane was busy")

        // The lane empties after this release, so the delay runs from later than now.
        let released = ContinuousClock.now
        whisper.isHeld = false
        for task in retranscriptions { try await finish(task, within: 2, "a re-transcription") }
        try await waitUntil("an engine is unloaded") { whisper.calls.contains(.unload) || cpp.calls.contains(.unload) }
        XCTAssertGreaterThanOrEqual(released.duration(to: .now), delay, "unloaded before the delay")
        try await waitUntil("both engines are unloaded") { whisper.calls.contains(.unload) && cpp.calls.contains(.unload) }

        XCTAssertEqual(whisper.calls, [.prepare(whisperBase), .transcribe(whisperBase), .transcribe(whisperBase), .unload])
        XCTAssertEqual(cpp.calls, [.prepare(cppBase), .transcribe(cppBase), .unload])
        XCTAssertEqual(apple.calls, [.prepare(.appleSpeech)], "unloaded the engine of the selected model")
    }

    // MARK: - Saved selection

    func testSelectedModelIDDefaultsToWhisperCppBase() {
        XCTAssertEqual(PreferencesManager.selectedModelID(saved: nil), .whisperCppBase)
        XCTAssertEqual(PreferencesManager.selectedModelID(saved: "garbage"), .whisperCppBase)
    }

    /// whisper-cli is retired (Task 27A); whisper.cpp base.en reads the same
    /// `ggml-base.en.bin` and gives the same text.
    func testSelectedModelIDMovesWhisperCLIChoicesToWhisperCppBase() {
        for saved in ["whisperCLI/tiny.en", "whisperCLI/base.en", "whisperCLI/small.en"] {
            XCTAssertEqual(PreferencesManager.selectedModelID(saved: saved), .whisperCppBase, saved)
        }
    }

    func testSelectedModelIDKeepsOtherChoices() {
        for saved in ["appleSpeech/en-US", "whisperKit/base.en", "whisperCpp/small.en"] {
            XCTAssertEqual(PreferencesManager.selectedModelID(saved: saved), ModelID(storageKey: saved), saved)
        }
    }

    /// The choice is saved as its `storageKey` under `selectedModelID`. The
    /// old app's `selectedModel` key no longer counts.
    func testSelectedModelIDIsSavedAsItsStorageKey() {
        let store = MemoryPreferenceStore()
        store.set("small.en", forKey: "selectedModel")
        let preferences = PreferencesManager(defaults: store)
        XCTAssertEqual(preferences.selectedModelID, .whisperCppBase)

        preferences.selectedModelID = whisperBase

        XCTAssertEqual(store.string(forKey: "selectedModelID"), "whisperKit/base.en")
        XCTAssertEqual(preferences.selectedModelID, whisperBase)
    }

    // MARK: - The fake

    func testFakeEngineHoldsTranscriptionsUntilReleased() async throws {
        let fake = FakeEngine(kind: .appleSpeech)
        fake.isHeld = true
        let finished = Order<String>()
        let held = Task {
            let text = try await fake.transcribe(clip, model: .appleSpeech, vocabulary: [])
            finished.append(text)
            return text
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(finished.values, [], "finished while held")

        fake.isHeld = false
        let text = try await finish(held, within: 1, "the held transcription")
        XCTAssertEqual(text, "hello")

        fake.isHeld = true
        let cancelled = Task { try await fake.transcribe(clip, model: .appleSpeech, vocabulary: []) }
        try await waitUntil("the second transcription is held") { fake.calls.count == 2 }
        cancelled.cancel()
        await assertCancelled(cancelled, within: 0.5)
        XCTAssertEqual(fake.cancelledCount, 1)
    }

    func testFakeEngineHoldsPreparesUntilReleased() async throws {
        let fake = FakeEngine(kind: .appleSpeech)
        fake.isPrepareHeld = true
        let finished = Order<String>()
        let held = Task {
            try await fake.prepare(.appleSpeech)
            finished.append("prepared")
        }
        try await waitUntil("the prepare has started") { fake.calls == [.prepare(.appleSpeech)] }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(finished.values, [], "prepared while held")

        fake.isPrepareHeld = false
        try await finish(held, within: 1, "the held prepare")
        XCTAssertEqual(finished.values, ["prepared"])
    }

    /// Fakes that share a log enter each call as it starts, and each prepare
    /// again once it has returned without an error.
    func testFakesShareOneCallLog() async throws {
        let log = CallLog()
        let apple = FakeEngine(kind: .appleSpeech, log: log)
        let whisper = FakeEngine(kind: .whisperKit, log: log)
        whisper.prepareError = TranscriptionError.modelNotReady("WhisperKit base.en is not downloaded")

        try await apple.prepare(.appleSpeech)
        try? await whisper.prepare(whisperBase)
        _ = try await whisper.transcribe(clip, model: whisperBase, vocabulary: [])
        await apple.unload()

        XCTAssertEqual(log.entries, [.call(.appleSpeech, .prepare(.appleSpeech)), .prepared(.appleSpeech),
                                     .call(.whisperKit, .prepare(whisperBase)),
                                     .call(.whisperKit, .transcribe(whisperBase)), .call(.appleSpeech, .unload)])
        XCTAssertEqual(apple.calls, [.prepare(.appleSpeech), .unload], "each fake still keeps its own calls")
    }

    // MARK: - Helpers

    private struct Timeout: Error {}

    /// Records values from any task, in the order they arrive.
    private final class Order<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Value] = []

        var values: [Value] { lock.withLock { items } }
        func append(_ value: Value) { lock.withLock { items.append(value) } }
    }

    /// A dictation that records `name` in `finished` once it returns.
    private func dictation(on service: TranscriptionService, recordingIn finished: Order<String>,
                           as name: String) -> Task<TranscriptionResult, Error> {
        let clip = clip
        return Task {
            let result = try await service.transcribe(clip, vocabulary: [])
            finished.append(name)
            return result
        }
    }

    /// The models of a fake's `transcribe` calls, in the order they started.
    private func transcriptions(_ engine: FakeEngine) -> [ModelID] {
        engine.calls.compactMap { call in
            if case .transcribe(let model) = call { return model }
            return nil
        }
    }

    private func descriptor(_ id: ModelID) -> ModelDescriptor {
        ModelDescriptor(id: id, displayName: id.storageKey, detail: "", state: .ready)
    }

    /// Polls every 10 ms until `condition` holds. Fails the test after
    /// `limit` seconds instead of hanging.
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

    /// The task's value. Fails the test if the task is still running after
    /// `limit` seconds, so a hang fails instead of blocking the suite.
    @discardableResult
    private func finish<T: Sendable>(_ task: Task<T, Error>, within limit: TimeInterval, _ what: String,
                                     file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        let ended = XCTestExpectation(description: what)
        Task {
            _ = await task.result
            ended.fulfill()
        }
        guard await XCTWaiter().fulfillment(of: [ended], timeout: limit) == .completed else {
            task.cancel()
            XCTFail("\(what) was still running after \(limit) s", file: file, line: line)
            throw Timeout()
        }
        return try await task.value
    }

    /// Waits at most `limit` seconds for `task` and asserts it threw
    /// `CancellationError`. A hang fails the test instead of blocking the suite.
    private func assertCancelled<T: Sendable>(_ task: Task<T, Error>, within limit: TimeInterval,
                                              file: StaticString = #filePath, line: UInt = #line) async {
        let ended = XCTestExpectation(description: "cancelled task ended")
        Task {
            _ = await task.result
            ended.fulfill()
        }
        guard await XCTWaiter().fulfillment(of: [ended], timeout: limit) == .completed else {
            return XCTFail("still running \(limit) s after the cancel", file: file, line: line)
        }
        switch await task.result {
        case .success:
            XCTFail("finished instead of stopping", file: file, line: line)
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "threw \(error)", file: file, line: line)
        }
    }
}
