import Foundation

/// What one transcription produced.
public struct TranscriptionResult: Sendable, Equatable {
    /// The engine's text after `OutputFilter.clean`.
    public let text: String
    public let model: ModelID
    /// Seconds the engine spent on the clip. Waiting in line, preparing the
    /// model, and an attempt a dictation stopped are not counted.
    public let elapsed: TimeInterval
}

/// Owns the engines and the model chosen for dictation, keeps that model
/// loaded, and runs every transcription, one at a time, in two lanes.
///
/// Dictations run one at a time, in call order. Re-transcriptions run one at
/// a time, in call order, and only while no dictation is running or waiting.
/// A dictation that arrives while a re-transcription transcribes stops it; the
/// re-transcription runs again from the start once the dictations are done,
/// and its caller only waits longer. A re-transcription prepares its model
/// before it waits to transcribe, so a dictation never waits for that load.
///
/// The service unloads engines, not models (Ruling T8-1): an engine is
/// unloaded only when nothing is using it and the selected model is not one
/// of its models. That is at once when `select` moves dictation to another
/// engine, and otherwise `idleUnloadDelay` seconds after its last use.
public actor TranscriptionService {
    /// The model dictations use.
    public private(set) var selected: ModelID

    private let engines: [TranscriptionEngine]
    private let idleUnloadDelay: TimeInterval

    /// Models prepared since their engine was last unloaded.
    private var ready: Set<ModelID> = []
    /// Prepares in flight, shared by everyone waiting for the same model.
    private var preparing: [ModelID: Task<Void, Error>] = [:]
    /// Why each model's last prepare failed, until one succeeds.
    private var prepareFailures: [ModelID: TranscriptionError] = [:]

    /// Calls and prepares using each engine. An engine is unloaded only at 0.
    private var users: [EngineKind: Int] = [:]
    /// Unloads waiting out `idleUnloadDelay`, cancelled by the next use.
    private var idleUnloads: [EngineKind: Task<Void, Never>] = [:]
    /// Each engine's latest unload. A prepare on that engine waits for it.
    private var unloads: [EngineKind: Task<Void, Never>] = [:]

    /// Who may transcribe. A dictation holds it while its model prepares too.
    private var slot: Lane?
    /// The turns someone has: the re-transcription lane, and `select`.
    private var turnsTaken: Set<Turn> = []
    /// Everyone waiting for the slot or a turn, in arrival order.
    private var waiting: [Waiter] = []
    private var nextWaiterID = 0
    /// The re-transcription now transcribing, so a dictation can stop it.
    private var retranscribing: Task<String, Error>?
    /// Set when a dictation asks the re-transcription holding the slot to stop.
    private var preempted = false

    public init(engines: [TranscriptionEngine], selected: ModelID, idleUnloadDelay: TimeInterval = 60) {
        self.engines = engines
        self.selected = selected
        self.idleUnloadDelay = idleUnloadDelay
    }

    /// Every engine's models, in the order the engines were given.
    public func allModels() async -> [ModelDescriptor] {
        var models: [ModelDescriptor] = []
        for engine in engines { models += await engine.models() }
        return models
    }

    /// Prepares `id`, makes it the model dictations use, then unloads the
    /// previous model's engine if it is a different one. An engine still in
    /// use is unloaded `idleUnloadDelay` seconds after its last use instead.
    /// A model that cannot prepare throws `modelNotReady` and changes nothing,
    /// as does a cancelled call. Calls take effect one at a time, in call order.
    public func select(_ id: ModelID) async throws {
        try await take(.selection)
        defer { pass(.selection) }
        let engine = try engine(for: id)
        beginUse(id.engine)
        defer { endUse(id.engine) }
        try await prepare(id, on: engine)
        try Task.checkCancellation()
        let previous = selected
        selected = id
        if previous.engine != id.engine, users[previous.engine, default: 0] == 0 {
            unload(previous.engine, because: "\(id.storageKey) is selected")
        }
    }

    /// Prepares the selected model; called at launch. A failure is kept
    /// (`prepareFailure(of:)`) and logged, not thrown. The next dictation
    /// prepares the model again and throws if it still cannot load.
    public func prepareSelected() async {
        let id = selected
        guard let engine = try? engine(for: id) else { return }
        try? await prepare(id, on: engine)
    }

    /// Transcribes a dictation with the selected model. Dictations run one at
    /// a time, in call order, ahead of every re-transcription. If the model is
    /// still preparing, the dictation waits for it (Review Focus 1). Throws
    /// `modelNotReady` when the model cannot prepare, and `CancellationError`
    /// when the caller is cancelled.
    public func transcribe(_ clip: AudioClip, vocabulary: [String]) async throws -> TranscriptionResult {
        try await takeSlot(for: .dictation)
        defer { releaseSlot() }
        let id = selected
        let engine = try engine(for: id)
        beginUse(id.engine)
        defer { endUse(id.engine) }
        try await prepare(id, on: engine)
        try Task.checkCancellation()
        let start = ContinuousClock.now
        let text = try await engine.transcribe(clip, model: id, vocabulary: vocabulary)
        try Task.checkCancellation()
        return Self.result(text, model: id, since: start)
    }

    /// Transcribes `clip` with `id` without changing the selection.
    /// Re-transcriptions run one at a time, in call order, and only while no
    /// dictation is running or waiting. A dictation that arrives during the
    /// transcription stops it, and it runs again from the start once the
    /// dictations are done. The caller sees `CancellationError` only when it
    /// is cancelled itself.
    public func transcribe(_ clip: AudioClip, with id: ModelID, vocabulary: [String]) async throws -> TranscriptionResult {
        let engine = try engine(for: id)
        beginUse(id.engine)
        defer { endUse(id.engine) }
        try await take(.retranscriptions)
        defer { pass(.retranscriptions) }
        // Outside the slot, so dictations go ahead while the model loads.
        try await prepare(id, on: engine)
        while true {
            try await takeSlot(for: .retranscription)
            // A dictation may have arrived while the slot was being handed
            // over. Nothing suspends from here until `retranscribing` is set.
            guard !isWaiting(.slot(.dictation)) else {
                releaseSlot()
                continue
            }
            preempted = false
            let start = ContinuousClock.now
            let attempt = Task { try await engine.transcribe(clip, model: id, vocabulary: vocabulary) }
            retranscribing = attempt
            let outcome = await withTaskCancellationHandler {
                await attempt.result
            } onCancel: {
                attempt.cancel()
            }
            retranscribing = nil
            let stopped = preempted
            releaseSlot()
            try Task.checkCancellation()
            switch outcome {
            case .success(let text):
                return Self.result(text, model: id, since: start)
            case .failure(let error):
                // Stopped for a dictation: run again once it is done.
                if !stopped { throw error }
            }
        }
    }

    /// Downloads `id` with its engine, reporting progress from 0 to 1.
    public func download(_ id: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await engine(for: id).download(id, progress: progress)
    }

    /// Deletes the files of `id`. The selected model is refused.
    public func delete(_ id: ModelID) async throws {
        guard id != selected else {
            throw TranscriptionError.failed("The model used for dictation cannot be deleted")
        }
        try await engine(for: id).delete(id)
        ready.remove(id)
    }

    /// Why `id` last failed to prepare, as `modelNotReady`; nil once a
    /// prepare succeeds.
    func prepareFailure(of id: ModelID) -> TranscriptionError? {
        prepareFailures[id]
    }

    // MARK: - Preparing models

    /// Returns once `id` is loaded: at once if it is, otherwise after a
    /// prepare, joining the one in flight. A cancelled caller stops waiting
    /// at once; the prepare carries on for whoever needs the model next.
    private func prepare(_ id: ModelID, on engine: TranscriptionEngine) async throws {
        guard !ready.contains(id) else { return }
        try await Self.join(preparing[id] ?? startPreparing(id, on: engine))
    }

    /// Prepares `id` in a task of its own, after any unload of its engine.
    /// A failure becomes `modelNotReady` and is kept until a prepare succeeds.
    private func startPreparing(_ id: ModelID, on engine: TranscriptionEngine) -> Task<Void, Error> {
        beginUse(id.engine)
        let unloading = unloads[id.engine]
        let task = Task {
            defer {
                self.preparing[id] = nil
                self.endUse(id.engine)
            }
            await unloading?.value
            do {
                try await engine.prepare(id)
            } catch {
                let reason = Self.reason(error, preparing: id)
                Log.info("[SERVICE] Could not prepare \(id.storageKey): \(reason)")
                self.prepareFailures[id] = .modelNotReady(reason)
                throw TranscriptionError.modelNotReady(reason)
            }
            self.ready.insert(id)
            self.prepareFailures[id] = nil
        }
        preparing[id] = task
        return task
    }

    /// Waits for a prepare without being tied to it: a cancelled caller stops
    /// waiting at once, and the prepare goes on.
    private static func join(_ prepare: Task<Void, Error>) async throws {
        let ended = AsyncThrowingStream<Void, Error> { continuation in
            Task {
                continuation.yield(with: await prepare.result)
                continuation.finish()
            }
        }
        for try await _ in ended { return }
        throw CancellationError()
    }

    /// The engine's own words for a failed prepare, when it gave any.
    private static func reason(_ error: Error, preparing id: ModelID) -> String {
        switch error {
        case TranscriptionError.modelNotReady(let reason), TranscriptionError.engineUnavailable(let reason),
             TranscriptionError.failed(let reason):
            return reason
        default:
            return "\(id.storageKey) could not be prepared: \(error.localizedDescription)"
        }
    }

    // MARK: - Unloading engines

    /// Something is about to use the engine: it stays loaded until `endUse`.
    private func beginUse(_ kind: EngineKind) {
        users[kind, default: 0] += 1
        idleUnloads.removeValue(forKey: kind)?.cancel()
    }

    /// Once nothing uses an engine that does not hold the selected model, it
    /// is unloaded after `idleUnloadDelay`, unless something uses it first.
    private func endUse(_ kind: EngineKind) {
        users[kind, default: 0] -= 1
        guard users[kind] == 0, kind != selected.engine else { return }
        let delay = idleUnloadDelay
        idleUnloads[kind]?.cancel()
        idleUnloads[kind] = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.idleUnloads[kind] = nil
            guard self.users[kind, default: 0] == 0, kind != self.selected.engine else { return }
            self.unload(kind, because: "unused for \(String(format: "%g", delay)) s")
        }
    }

    /// Unloads the engine now. Its models are prepared again before their
    /// next use, and that prepare waits for this unload to finish.
    private func unload(_ kind: EngineKind, because reason: String) {
        guard let engine = engines.first(where: { $0.kind == kind }) else { return }
        idleUnloads.removeValue(forKey: kind)?.cancel()
        ready = ready.filter { $0.engine != kind }
        let previous = unloads[kind]
        unloads[kind] = Task {
            await previous?.value
            await engine.unload()
        }
        Log.info("[SERVICE] Unloading \(kind.rawValue): \(reason)")
    }

    // MARK: - Lines

    private enum Lane { case dictation, retranscription }
    private enum Turn { case retranscriptions, selection }

    private struct Waiter {
        enum Purpose: Equatable { case slot(Lane), turn(Turn) }

        let id: Int
        let purpose: Purpose
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Takes the slot at once if it is free and no dictation is waiting, and
    /// otherwise waits in line. A dictation stops a re-transcription that
    /// holds the slot.
    private func takeSlot(for lane: Lane) async throws {
        if slot == nil, !isWaiting(.slot(.dictation)) {
            slot = lane
            return
        }
        if lane == .dictation, slot == .retranscription {
            preempted = true
            retranscribing?.cancel()
        }
        try await waitInLine(for: .slot(lane))
    }

    /// Hands the slot to the first dictation waiting, else to the
    /// re-transcription waiting, else frees it.
    private func releaseSlot() {
        if resumeFirst(.slot(.dictation)) {
            slot = .dictation
        } else if resumeFirst(.slot(.retranscription)) {
            slot = .retranscription
        } else {
            slot = nil
        }
    }

    /// Takes the turn at once if no one has it, and otherwise waits in line.
    private func take(_ turn: Turn) async throws {
        if turnsTaken.insert(turn).inserted { return }
        try await waitInLine(for: .turn(turn))
    }

    /// Hands the turn to the first in line, or frees it.
    private func pass(_ turn: Turn) {
        if !resumeFirst(.turn(turn)) { turnsTaken.remove(turn) }
    }

    /// Returns when `resumeFirst` hands this caller what it waits for. A
    /// cancelled caller leaves the line at once with `CancellationError`.
    private func waitInLine(for purpose: Waiter.Purpose) async throws {
        let id = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting.append(Waiter(id: id, purpose: purpose, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.leaveLine(id) }
        }
    }

    /// A cancelled caller's exit, unless it was already handed its turn.
    private func leaveLine(_ id: Int) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Resumes the longest-waiting caller with this purpose; false if none.
    private func resumeFirst(_ purpose: Waiter.Purpose) -> Bool {
        guard let index = waiting.firstIndex(where: { $0.purpose == purpose }) else { return false }
        waiting.remove(at: index).continuation.resume()
        return true
    }

    private func isWaiting(_ purpose: Waiter.Purpose) -> Bool {
        waiting.contains { $0.purpose == purpose }
    }

    // MARK: - Helpers

    private func engine(for id: ModelID) throws -> TranscriptionEngine {
        guard let engine = engines.first(where: { $0.kind == id.engine }) else {
            throw TranscriptionError.engineUnavailable("No engine runs \(id.storageKey)")
        }
        return engine
    }

    private static func result(_ text: String, model: ModelID, since start: ContinuousClock.Instant) -> TranscriptionResult {
        let elapsed = start.duration(to: .now).components
        return TranscriptionResult(
            text: OutputFilter.clean(text), model: model,
            elapsed: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        )
    }

    // MARK: - For tests

    /// Dictations in line: the one holding the slot and those waiting for it.
    var dictationsInLine: Int {
        (slot == .dictation ? 1 : 0) + waiting.filter { $0.purpose == .slot(.dictation) }.count
    }

    /// Re-transcriptions in line: the one whose turn it is and those waiting.
    var retranscriptionsInLine: Int {
        (turnsTaken.contains(.retranscriptions) ? 1 : 0) + waiting.filter { $0.purpose == .turn(.retranscriptions) }.count
    }
}
