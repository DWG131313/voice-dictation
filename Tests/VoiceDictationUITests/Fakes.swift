import Foundation
@testable import VoiceDictationLib

// Slim copies of the fakes in VoiceDictationTests, which this test module
// cannot see.

/// Preferences kept in a dictionary, so a test writes no preferences file.
final class MemoryPreferenceStore: PreferenceStore {
    private var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func integer(forKey defaultName: String) -> Int { values[defaultName] as? Int ?? 0 }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

/// An engine that lists the models it is given and records its calls. All
/// state sits behind one lock so it is safe to share.
final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
    enum Call: Equatable { case prepare(ModelID), transcribe(ModelID), download(ModelID) }

    let kind: EngineKind
    private let lock = NSLock()
    private var _models: [ModelDescriptor]
    private var _result = "Hello there."
    private var _isHeld = false
    private var _unloadable: Set<ModelID> = []
    private var _calls: [Call] = []

    init(kind: EngineKind, models: [ModelDescriptor] = []) {
        self.kind = kind
        _models = models
    }

    var modelList: [ModelDescriptor] {
        get { lock.withLock { _models } }
        set { lock.withLock { _models = newValue } }
    }
    var result: String {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }
    /// While true, each `transcribe` waits once it has started.
    var isHeld: Bool {
        get { lock.withLock { _isHeld } }
        set { lock.withLock { _isHeld = newValue } }
    }
    /// Models whose `prepare` fails.
    var unloadable: Set<ModelID> {
        get { lock.withLock { _unloadable } }
        set { lock.withLock { _unloadable = newValue } }
    }
    var calls: [Call] { lock.withLock { _calls } }

    private func record(_ call: Call) { lock.withLock { _calls.append(call) } }

    func models() async -> [ModelDescriptor] { modelList }

    func prepare(_ model: ModelID) async throws {
        record(.prepare(model))
        if unloadable.contains(model) { throw TranscriptionError.modelNotReady("\(model.name) will not load") }
    }

    func transcribe(_ clip: AudioClip, model: ModelID, vocabulary: [String]) async throws -> String {
        record(.transcribe(model))
        while isHeld { try await Task.sleep(nanoseconds: 2_000_000) }
        return result
    }

    func download(_ model: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        record(.download(model))
        progress(1)
    }

    func delete(_ model: ModelID) async throws {}
    func unload() async {}
}

/// A recorder that calls its delegate the way `AudioRecorder` does, without
/// a microphone. Use from the main thread, as the real one.
final class FakeRecorder: Recording {
    weak var delegate: AudioRecorderDelegate?
    var onLevel: ((Float) -> Void)?
    var onFirstAudio: ((Date) -> Void)?

    /// What the next stop hands over.
    var nextClip = AudioClip(samples: [Float](repeating: 0.2, count: 16_000))
    private(set) var isRecording = false

    func prepare() {}

    func startRecording() {
        isRecording = true
        delegate?.recordingDidStart()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        delegate?.recordingDidFinish(clip: nextClip)
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        delegate?.recordingDiscarded()
    }
}

/// A paster that records what it was asked to paste instead of pasting it.
final class FakePaster: Pasting {
    var frontmostAppName: String? = "TextEdit"
    private(set) var pasted: [String] = []

    func paste(text: String) -> Bool {
        pasted.append(text)
        return true
    }
}
