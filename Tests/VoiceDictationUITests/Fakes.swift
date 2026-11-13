import Foundation
@testable import VoiceDictationLib
@testable import VoiceDictationUI

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
    private var _delay: TimeInterval = 0
    private var _unloadable: Set<ModelID> = []
    private var _calls: [Call] = []
    private var _onDownload: (@Sendable (ModelID, @escaping @Sendable (Double) -> Void) async throws -> Void)?

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
    /// How long each `transcribe` takes once it is let go, in seconds.
    var delay: TimeInterval {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }
    /// Models whose `prepare` fails.
    var unloadable: Set<ModelID> {
        get { lock.withLock { _unloadable } }
        set { lock.withLock { _unloadable = newValue } }
    }
    var calls: [Call] { lock.withLock { _calls } }
    /// Replaces the download: it reports progress through the closure it is
    /// given, and throws (`CancellationError` when cancelled) like an engine.
    var onDownload: (@Sendable (ModelID, @escaping @Sendable (Double) -> Void) async throws -> Void)? {
        get { lock.withLock { _onDownload } }
        set { lock.withLock { _onDownload = newValue } }
    }

    private func record(_ call: Call) { lock.withLock { _calls.append(call) } }

    func models() async -> [ModelDescriptor] { modelList }

    func prepare(_ model: ModelID) async throws {
        record(.prepare(model))
        if unloadable.contains(model) { throw TranscriptionError.modelNotReady("\(model.name) will not load") }
    }

    func transcribe(_ clip: AudioClip, model: ModelID, vocabulary: [String]) async throws -> String {
        record(.transcribe(model))
        while isHeld { try await Task.sleep(nanoseconds: 2_000_000) }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        return result
    }

    func download(_ model: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        record(.download(model))
        if let onDownload { try await onDownload(model, progress); return }
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

/// A paster that records what it was asked to paste or copy instead of
/// touching the clipboard. Its change count goes up with each, as the
/// clipboard's does; a test adds to it for a copy made in another app.
final class FakePaster: Pasting {
    var frontmostAppName: String? = "TextEdit"
    /// False pastes nothing, as without Accessibility access.
    var succeeds = true
    var clipboardChangeCount = 0
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

/// The apps Paste again sees, in place of macOS's: nothing is hidden or
/// brought to the front. Process identifiers name the apps; this one is 1.
@MainActor
final class FakeApps {
    static let thisApp: pid_t = 1

    /// The app in front before this one; nil when there was none.
    var previous: pid_t? = 42
    var frontmost: pid_t? = FakeApps.thisApp
    /// The app that comes to the front when this one hides; nil leaves the
    /// front as it was, as a slow app would for a moment.
    var frontmostAfterHide: pid_t? = 42
    /// Run as this app hides and as it shows again: what SwiftUI might
    /// report then, such as the window closing and opening.
    var onHide: (() -> Void)?
    var onUnhide: (() -> Void)?
    private(set) var hides = 0
    private(set) var unhides = 0

    var system: PasteAgainSystem {
        PasteAgainSystem(
            previousApp: { self.previous },
            frontmostApp: { self.frontmost },
            hide: {
                self.hides += 1
                if let next = self.frontmostAfterHide { self.frontmost = next }
                self.onHide?()
            },
            unhide: {
                self.unhides += 1
                self.frontmost = FakeApps.thisApp
                self.onUnhide?()
            }
        )
    }
}

/// Stands in for `NSApplication` in `PasteAgainSystem.live(application:)`:
/// it records each call and hides or shows nothing.
@MainActor
final class FakeApplication: AppHiding {
    enum Call: Equatable { case hide, unhideWithoutActivation }

    private(set) var calls: [Call] = []

    func hide(_ sender: Any?) { calls.append(.hide) }
    func unhideWithoutActivation() { calls.append(.unhideWithoutActivation) }
}

/// Stands in for the app's calls on `NSApp` (`AppActivation`): each is
/// recorded and nothing is activated, hidden or switched.
@MainActor
final class FakeActivation {
    enum Call: Equatable { case regularPolicy, accessoryPolicy, activate, hide }

    private(set) var calls: [Call] = []
    /// What `NSApp.windows` would report: none, by default.
    var windows: [WindowSnapshot] = []
    /// What `NSApp.isHidden` would report: not hidden, by default.
    var isHidden = false

    func reset() { calls = [] }

    var activation: AppActivation {
        AppActivation(
            setRegularPolicy: { self.calls.append(.regularPolicy) },
            setAccessoryPolicy: { self.calls.append(.accessoryPolicy) },
            activate: { self.calls.append(.activate) },
            hide: { self.calls.append(.hide) },
            isHidden: { self.isHidden },
            windows: { self.windows })
    }
}

/// An indicator that keeps what it was asked to show instead of showing it.
@MainActor
final class FakeIndicator: IndicatorPresenting {
    /// The state shown last; nil before the first.
    private(set) var state: DictationState?
    /// The line shown last.
    private(set) var line = LevelLine()
    private(set) var isShowing = false

    func show(_ state: DictationState, line: LevelLine) {
        self.state = state
        self.line = line
        isShowing = true
    }

    func hide() {
        isShowing = false
    }

    /// On screen, saying "Listening".
    var showsListening: Bool {
        guard isShowing, case .recording? = state else { return false }
        return true
    }
}

extension OnboardingSystem {
    /// A system that asks for nothing, opens nothing and reads no real
    /// setting, so a test never touches `com.apple.HIToolbox`.
    static func fake(microphone: Bool = true, accessibility: Bool = true, globeKeyUsage: Int? = 0) -> OnboardingSystem {
        OnboardingSystem(
            microphoneGranted: { microphone }, microphoneUndetermined: { false }, requestMicrophone: {},
            accessibilityGranted: { accessibility }, requestAccessibility: {},
            globeKeyUsageType: { globeKeyUsage }, openURL: { _ in }, refreshPermissions: {}
        )
    }
}
