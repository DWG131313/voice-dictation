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

/// Preferences kept in a dictionary, so a test writes no preferences file.
final class MemoryPreferenceStore: PreferenceStore {
    private var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func integer(forKey defaultName: String) -> Int { values[defaultName] as? Int ?? 0 }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

/// One record of what several fakes did, in the order it happened, so a test
/// can see the order across engines.
final class CallLog: @unchecked Sendable {
    enum Entry: Equatable {
        /// A call to the engine of this kind, entered as it starts.
        case call(EngineKind, FakeEngine.Call)
        /// A `prepare` of this model that has returned without an error.
        case prepared(ModelID)
    }

    private let lock = NSLock()
    private var _entries: [Entry] = []

    var entries: [Entry] { lock.withLock { _entries } }
    func append(_ entry: Entry) { lock.withLock { _entries.append(entry) } }
}

/// A scriptable engine. All state sits behind one lock so it is safe to share.
final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
    enum Call: Equatable {
        case prepare(ModelID), transcribe(ModelID), download(ModelID), delete(ModelID), unload
    }

    let kind: EngineKind
    let probe: ConcurrencyProbe?
    /// Shared with other fakes, if given.
    let log: CallLog?
    private let lock = NSLock()
    private var _result = "hello"
    private var _delay: TimeInterval = 0
    private var _isHeld = false
    private var _prepareDelay: TimeInterval = 0
    private var _isPrepareHeld = false
    private var _prepareError: Error?
    private var _calls: [Call] = []
    private var _cancelledCount = 0
    private var _models: [ModelDescriptor] = []
    private var _textForClip: (@Sendable (AudioClip) -> String)?
    private var _clips: [AudioClip] = []

    init(kind: EngineKind = .appleSpeech, probe: ConcurrencyProbe? = nil, log: CallLog? = nil) {
        self.kind = kind
        self.probe = probe
        self.log = log
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
    /// While true, each `prepare` waits once it has started, before its
    /// `prepareDelay`, until the test sets this back to false.
    var isPrepareHeld: Bool {
        get { lock.withLock { _isPrepareHeld } }
        set { lock.withLock { _isPrepareHeld = newValue } }
    }
    var prepareError: Error? {
        get { lock.withLock { _prepareError } }
        set { lock.withLock { _prepareError = newValue } }
    }
    var modelList: [ModelDescriptor] {
        get { lock.withLock { _models } }
        set { lock.withLock { _models = newValue } }
    }
    /// When set, `transcribe` returns this clip's text instead of `result`.
    var textForClip: (@Sendable (AudioClip) -> String)? {
        get { lock.withLock { _textForClip } }
        set { lock.withLock { _textForClip = newValue } }
    }
    /// The clips `transcribe` was given, in the order the calls started.
    var transcribedClips: [AudioClip] { lock.withLock { _clips } }
    /// Every call in the order it started.
    var calls: [Call] { lock.withLock { _calls } }
    /// `transcribe` calls cancelled while held or during their `delay`.
    var cancelledCount: Int { lock.withLock { _cancelledCount } }

    private func record(_ call: Call) {
        lock.withLock { _calls.append(call) }
        log?.append(.call(kind, call))
    }

    func models() async -> [ModelDescriptor] { modelList }

    func prepare(_ model: ModelID) async throws {
        record(.prepare(model))
        while isPrepareHeld { try await Task.sleep(nanoseconds: 2_000_000) }
        let wait = prepareDelay
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        if let error = prepareError { throw error }
        log?.append(.prepared(model))
    }

    func transcribe(_ clip: AudioClip, model: ModelID, vocabulary: [String]) async throws -> String {
        lock.withLock { _clips.append(clip) }
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
        return textForClip?(clip) ?? result
    }

    func download(_ model: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        record(.download(model))
        progress(1)
    }

    func delete(_ model: ModelID) async throws { record(.delete(model)) }

    func unload() async { record(.unload) }
}

/// A scriptable cleaner. All state sits behind one lock: the pipeline calls
/// it off the main thread.
final class FakeCleaner: TextCleaner, @unchecked Sendable {
    private let lock = NSLock()
    private var _reply: (@Sendable (String) -> String)?
    private var _error: Error?
    private var _delay: TimeInterval = 0
    private var _isHeld = false
    private var _ignoresCancellation = false
    private var _isAvailable = true
    private var _onClean: (@Sendable (String) -> Void)?
    private var _given: [String] = []
    private var _finishedCount = 0
    private var _prewarmedOnMainThread: [Bool] = []

    /// What it makes of a text; nil gives the text back unchanged.
    var reply: (@Sendable (String) -> String)? {
        get { lock.withLock { _reply } }
        set { lock.withLock { _reply = newValue } }
    }
    /// When set, each cleanup throws it instead of replying.
    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }
    /// How long each cleanup takes, in seconds, once it is let go.
    var delay: TimeInterval {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }
    /// While true, each cleanup waits once it has started, before its `delay`.
    var isHeld: Bool {
        get { lock.withLock { _isHeld } }
        set { lock.withLock { _isHeld = newValue } }
    }
    /// When true, a cancelled cleanup carries on and replies all the same, as
    /// a model that does not stop at once.
    var ignoresCancellation: Bool {
        get { lock.withLock { _ignoresCancellation } }
        set { lock.withLock { _ignoresCancellation = newValue } }
    }
    var isAvailable: Bool {
        get { lock.withLock { _isAvailable } }
        set { lock.withLock { _isAvailable = newValue } }
    }
    /// Called with each text as its cleanup starts.
    var onClean: (@Sendable (String) -> Void)? {
        get { lock.withLock { _onClean } }
        set { lock.withLock { _onClean = newValue } }
    }
    /// The texts it was given, in the order the cleanups started.
    var given: [String] { lock.withLock { _given } }
    /// Cleanups that have replied or thrown.
    var finishedCount: Int { lock.withLock { _finishedCount } }
    var prewarmCount: Int { lock.withLock { _prewarmedOnMainThread.count } }
    /// For each prewarm, in the order they ran, whether it ran on the main thread.
    var prewarmedOnMainThread: [Bool] { lock.withLock { _prewarmedOnMainThread } }

    func prewarm() {
        let onMainThread = Thread.isMainThread
        lock.withLock { _prewarmedOnMainThread.append(onMainThread) }
    }

    func clean(_ raw: String) async throws -> String {
        lock.withLock { _given.append(raw) }
        onClean?(raw)
        defer { lock.withLock { _finishedCount += 1 } }
        if ignoresCancellation {
            while isHeld { await Self.sleepThroughCancellation(0.002) }
            await Self.sleepThroughCancellation(delay)
        } else {
            while isHeld { try await Task.sleep(nanoseconds: 2_000_000) }
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        }
        if let error { throw error }
        return reply?(raw) ?? raw
    }

    /// Waits `seconds` whether or not the task is cancelled.
    private static func sleepThroughCancellation(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }
}

/// A recorder that calls its delegate the way `AudioRecorder` does, without
/// a microphone. Use from the main thread, as the real one.
final class FakeRecorder: Recording {
    weak var delegate: AudioRecorderDelegate?
    var onLevel: ((Float) -> Void)?
    var onFirstAudio: ((Date) -> Void)?
    var inputDeviceUID: String?

    /// What the next stop hands over; nil makes the recording too short to keep.
    var nextClip: AudioClip?
    /// When set, starting fails with this message, as without microphone access.
    var startFailure: String?
    /// When true, starting waits, as for the microphone permission prompt,
    /// until `startNow()`.
    var startsLater = false

    private(set) var isRecording = false
    private(set) var prepareCount = 0
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    func prepare() { prepareCount += 1 }

    func startRecording() {
        startCount += 1
        if let startFailure {
            delegate?.recordingDidFail(error: startFailure)
        } else if !startsLater {
            startNow()
        }
    }

    /// Starts a recording, as after the microphone permission prompt.
    func startNow() {
        isRecording = true
        delegate?.recordingDidStart()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let clip = nextClip {
            delegate?.recordingDidFinish(clip: clip)
        } else {
            delegate?.recordingDiscarded()
        }
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        cancelCount += 1
        delegate?.recordingDiscarded()
    }
}

/// A paster that records what it was asked to paste or copy instead of
/// touching the clipboard.
final class FakePaster: Pasting {
    /// False pastes nothing, as without Accessibility access.
    var succeeds = true
    var frontmostAppName: String? = "TextEdit"
    /// Goes up with each paste and copy, as the clipboard's does.
    private(set) var clipboardChangeCount = 0
    private(set) var pasted: [String] = []
    private(set) var copied: [String] = []

    func paste(text: String) -> Bool {
        pasted.append(text)
        clipboardChangeCount += 1
        return succeeds
    }

    func copy(text: String) {
        copied.append(text)
        clipboardChangeCount += 1
    }
}
