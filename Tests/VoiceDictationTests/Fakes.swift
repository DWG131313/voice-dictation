import Foundation
@testable import VoiceDictationLib

/// Counts `transcribe` calls running at once across every fake that shares it.
final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private var peak = 0

    var maxRunning: Int { lock.withLock { peak } }

    func enter() { lock.withLock { running += 1; peak = max(peak, running) } }
    func leave() { lock.withLock { running -= 1 } }
}

/// A scriptable engine. All state sits behind one lock so it is safe to share.
final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
    enum Call: Equatable {
        case prepare(ModelID), transcribe(ModelID), download(ModelID), delete(ModelID), unload
    }

    let kind: EngineKind
    let probe: ConcurrencyProbe?
    private let lock = NSLock()
    private var _result = "hello"
    private var _delay: TimeInterval = 0
    private var _isHeld = false
    private var _prepareDelay: TimeInterval = 0
    private var _prepareError: Error?
    private var _calls: [Call] = []
    private var _cancelledCount = 0
    private var _models: [ModelDescriptor] = []

    init(kind: EngineKind = .appleSpeech, probe: ConcurrencyProbe? = nil) {
        self.kind = kind
        self.probe = probe
    }

    var result: String {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }
    var delay: TimeInterval {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }
    /// While true, each `transcribe` waits once it has started, before its
    /// `delay`, until the test sets this back to false.
    var isHeld: Bool {
        get { lock.withLock { _isHeld } }
        set { lock.withLock { _isHeld = newValue } }
    }
    var prepareDelay: TimeInterval {
        get { lock.withLock { _prepareDelay } }
        set { lock.withLock { _prepareDelay = newValue } }
    }
    var prepareError: Error? {
        get { lock.withLock { _prepareError } }
        set { lock.withLock { _prepareError = newValue } }
    }
    var modelList: [ModelDescriptor] {
        get { lock.withLock { _models } }
        set { lock.withLock { _models = newValue } }
    }
    /// Every call in the order it started.
    var calls: [Call] { lock.withLock { _calls } }
    /// `transcribe` calls cancelled while held or during their `delay`.
    var cancelledCount: Int { lock.withLock { _cancelledCount } }

    private func record(_ call: Call) { lock.withLock { _calls.append(call) } }

    func models() async -> [ModelDescriptor] { modelList }

    func prepare(_ model: ModelID) async throws {
        record(.prepare(model))
        let wait = prepareDelay
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        if let error = prepareError { throw error }
    }

    func transcribe(_ clip: AudioClip, model: ModelID, vocabulary: [String]) async throws -> String {
        record(.transcribe(model))
        probe?.enter()
        defer { probe?.leave() }
        do {
            while isHeld { try await Task.sleep(nanoseconds: 2_000_000) }
            let wait = delay
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        } catch {
            lock.withLock { _cancelledCount += 1 }
            throw error
        }
        return result
    }

    func download(_ model: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        record(.download(model))
        progress(1)
    }

    func delete(_ model: ModelID) async throws { record(.delete(model)) }

    func unload() async { record(.unload) }
}
