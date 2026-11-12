import Foundation
import Observation

/// What the pipeline needs from the microphone recorder (`AudioRecorder`).
/// Every call and callback happens on the main thread.
public protocol Recording: AnyObject {
    var delegate: AudioRecorderDelegate? { get set }
    /// The peak (0...1) of each stretch of audio while recording.
    var onLevel: ((Float) -> Void)? { get set }
    /// When a recording's first audio arrived: at most once per recording,
    /// always before that recording's delegate call.
    var onFirstAudio: ((Date) -> Void)? { get set }
    /// Readies the microphone so the next recording starts at once, without
    /// starting it.
    func prepare()
    func startRecording()
    /// Ends the recording and calls the delegate before returning.
    func stopRecording()
    /// Ends the recording and throws it away.
    func cancelRecording()
}

extension AudioRecorder: Recording {}

/// Puts text into the frontmost app.
public protocol Pasting {
    /// Puts `text` on the clipboard and pastes it into the frontmost app.
    /// Returns false when it could not paste; the text then stays on the
    /// clipboard.
    func paste(text: String) -> Bool
    /// The app a paste would go to.
    var frontmostAppName: String? { get }
}

/// Runs each dictation from key press to paste. It records while the hotkey
/// is held, has the service transcribe each recording with the selected
/// model, in the order they were made, and pastes the text into the frontmost
/// app. Every dictation that is not cancelled is reported once, through
/// `onOutcome`. Use from the main thread.
///
/// At most `maximumWaiting` recordings wait behind the one being transcribed.
/// When another arrives, the oldest waiting one is skipped: never
/// transcribed, and reported as Failed with its audio (Review Focus 4).
@MainActor @Observable
public final class DictationPipeline {
    public static let maximumWaiting = 3
    /// The failure reported for a dictation skipped from a full line.
    public static let skippedFailure = "Skipped: too many dictations waiting"

    /// What the app is doing. An error shows for `errorDisplaySeconds`, then
    /// the state returns to the true one.
    public private(set) var state: DictationState = .idle
    /// The latest input peak while recording (0...1), for the indicator.
    public private(set) var level: Float = 0
    /// Called once for every finished dictation; a cancelled one has none.
    @ObservationIgnored public var onOutcome: ((DictationOutcome) -> Void)?
    /// A permission dictation lacks ("Accessibility", "Microphone"). It shows
    /// as `.needsPermission` whenever there is nothing else to show.
    public var missingPermission: String? {
        didSet { settle() }
    }

    /// How long an error stays on show.
    @ObservationIgnored var errorDisplaySeconds: TimeInterval = 5
    /// The marks of the dictation pasted last, as logged.
    @ObservationIgnored private(set) var lastTiming: StageTimer?

    @ObservationIgnored private let recorder: Recording
    @ObservationIgnored private let service: TranscriptionService
    @ObservationIgnored private let paster: Pasting
    // Tasks 21 and 22 add cleanup and replacements between the service's
    // text and the paste; until then the app passes no cleaner and no rules.
    @ObservationIgnored private let cleaner: TextCleaner?
    @ObservationIgnored private let replacements: () -> [Replacement]
    @ObservationIgnored private let vocabulary: () -> [String]

    /// The dictation being recorded, from key-down until its recording ends.
    @ObservationIgnored private var capture: Capture?
    /// Recordings handed to the service, oldest first: the first is being
    /// transcribed, the rest wait.
    @ObservationIgnored private var line: [Dictation] = []
    /// Whether `finishLine` is running.
    @ObservationIgnored private var isFinishingLine = false
    @ObservationIgnored private var errorMessage: String?
    @ObservationIgnored private var errorTimer: Task<Void, Never>?
    /// Models being chosen, by name, latest last.
    @ObservationIgnored private var modelsPreparing: [String] = []
    /// What `pasteLast` pastes: the text of the last dictation that had one.
    @ObservationIgnored private var lastText: String?

    public init(recorder: Recording, service: TranscriptionService, paster: Pasting,
                cleaner: TextCleaner?, replacements: @escaping () -> [Replacement], vocabulary: @escaping () -> [String]) {
        self.recorder = recorder
        self.service = service
        self.paster = paster
        self.cleaner = cleaner
        self.replacements = replacements
        self.vocabulary = vocabulary
        recorder.delegate = self
        recorder.onLevel = { [weak self] level in
            guard let self, self.capture != nil else { return }
            self.level = level
        }
        recorder.onFirstAudio = { [weak self] time in
            self?.capture?.timer.mark(.firstAudio, at: time)
        }
        // Ready the microphone so the first syllable is not lost.
        recorder.prepare()
    }

    // MARK: - The hotkey

    public func hotkeyDown() {
        guard capture == nil else { return }
        var timer = StageTimer()
        timer.mark(.keyDown)
        capture = Capture(timer: timer)
        // A new dictation replaces whatever went wrong before it.
        clearError()
        // The recorder calls back before returning, unless it is asking for
        // microphone access first.
        recorder.startRecording()
        settle()
    }

    public func hotkeyUp() {
        guard var capture else { return }
        guard capture.startedAt != nil else {
            // Still waiting for microphone access: there is nothing to stop.
            self.capture = nil
            settle()
            return
        }
        capture.keyUpAt = Date()
        self.capture = capture
        recorder.stopRecording()
    }

    /// Escape. While recording, cancels the recording only, so dictations
    /// already in line still paste. Otherwise cancels every dictation in
    /// line. A cancelled dictation pastes nothing, reports no outcome, and
    /// leaves no audio behind.
    public func cancel() {
        if let capture {
            self.capture = nil
            if capture.startedAt != nil { recorder.cancelRecording() }
            level = 0
            settle()
            return
        }
        guard !line.isEmpty else { return }
        let cancelled = line
        line.removeAll()
        cancelled.forEach { $0.transcription.cancel() }
        Log.info("[PIPELINE] Cancelled \(cancelled.count) dictation(s) in line")
        settle()
    }

    /// Pastes the text of the last dictation again (Ruling P4: kept in
    /// memory; Task 23 points this at the transcript store).
    public func pasteLast() {
        guard let text = lastText else {
            Log.info("[PIPELINE] Paste last: nothing dictated yet")
            return
        }
        if !paster.paste(text: text) {
            Log.info("[PIPELINE] Paste last: could not paste, text left on the clipboard")
        }
    }

    // MARK: - Choosing a model

    /// Makes `id` the model dictations use, downloading it first when asked.
    /// Shows `.preparingModel(name)` meanwhile, whenever nothing more urgent
    /// is showing. A failure is shown as an error and rethrown; the selection
    /// is then unchanged.
    public func selectModel(_ id: ModelID, named name: String, downloadingFirst: Bool = false) async throws {
        modelsPreparing.append(name)
        settle()
        defer {
            if let index = modelsPreparing.lastIndex(of: name) { modelsPreparing.remove(at: index) }
            settle()
        }
        do {
            if downloadingFirst {
                Log.info("[PIPELINE] Downloading \(id.storageKey)")
                try await service.download(id) { _ in }
            }
            try await service.select(id)
            Log.info("[PIPELINE] Dictating with \(id.storageKey)")
        } catch {
            let reason = Self.describe(error)
            Log.info("[PIPELINE] Could not switch to \(id.storageKey): \(reason)")
            show(reason)
            throw error
        }
    }

    // MARK: - The line

    /// Hands a finished recording to the service. It goes in line behind
    /// the dictations already there, and a full line skips its oldest
    /// waiting dictation.
    private func enqueue(_ clip: AudioClip, timer: StageTimer) {
        let service = self.service
        let words = vocabulary()
        // Each call goes to the service now, so the service sees every
        // dictation waiting and keeps re-transcriptions behind them.
        let transcription = Task { () -> Transcription in
            do {
                let result = try await service.transcribe(clip, vocabulary: words)
                return Transcription(result: .success(result), model: result.model)
            } catch {
                return Transcription(result: .failure(error), model: await service.selected)
            }
        }
        line.append(Dictation(date: Date(), clip: clip, timer: timer, transcription: transcription))
        if line.count - 1 > Self.maximumWaiting {
            skip(line.remove(at: 1))
        }
        settle()
        if !isFinishingLine {
            isFinishingLine = true
            Task { await finishLine() }
        }
    }

    /// Finishes the dictations in line one at a time, oldest first, so they
    /// paste in the order they were made.
    private func finishLine() async {
        while let dictation = line.first {
            let transcription = await dictation.transcription.value
            // Gone means cancelled while it was transcribing.
            guard line.first?.id == dictation.id else { continue }
            line.removeFirst()
            finish(dictation, transcription)
        }
        isFinishingLine = false
        settle()
    }

    private func finish(_ dictation: Dictation, _ transcription: Transcription) {
        var timer = dictation.timer
        timer.mark(.textReady)
        switch transcription.result {
        case .success(let result):
            guard !result.text.isEmpty else {
                Log.info("[PIPELINE] \(result.model.storageKey) heard nothing; nothing pasted")
                return
            }
            let appName = paster.frontmostAppName
            let pasted = paster.paste(text: result.text)
            timer.mark(.pasted)
            lastTiming = timer
            Log.info("[TIMING] \(timer.summary)")
            Log.info("[PIPELINE] \(pasted ? "Pasted" : "Could not paste, left on the clipboard:") \(result.text.count) chars from \(result.model.storageKey) in \(String(format: "%.2f", result.elapsed)) s")
            lastText = result.text
            onOutcome?(DictationOutcome(
                id: dictation.id, date: dictation.date, clip: dictation.clip,
                rawText: result.text, text: result.text, model: result.model,
                transcribeSeconds: result.elapsed, appName: appName, status: pasted ? .pasted : .copied
            ))
        case .failure(let error):
            let reason = Self.describe(error)
            Log.info("[PIPELINE] Transcription with \(transcription.model.storageKey) failed: \(reason)")
            report(failed: dictation, model: transcription.model, reason: reason)
            show(reason)
        }
    }

    /// Takes a waiting dictation out of line before it is transcribed and
    /// reports it as Failed, keeping its audio.
    private func skip(_ dictation: Dictation) {
        dictation.transcription.cancel()
        Log.info("[PIPELINE] More than \(Self.maximumWaiting) dictations waiting; skipped the oldest")
        show(Self.skippedFailure)
        Task {
            // Its call to the service leaves the line at once, saying which
            // model was selected.
            let model = await dictation.transcription.value.model
            report(failed: dictation, model: model, reason: Self.skippedFailure)
        }
    }

    private func report(failed dictation: Dictation, model: ModelID, reason: String) {
        onOutcome?(DictationOutcome(
            id: dictation.id, date: dictation.date, clip: dictation.clip, rawText: "", text: "",
            model: model, transcribeSeconds: 0, appName: paster.frontmostAppName,
            status: .failed, failure: reason
        ))
    }

    // MARK: - State

    /// Shows an error, then after `errorDisplaySeconds` the true state.
    private func show(_ message: String) {
        errorTimer?.cancel()
        errorMessage = message
        let seconds = errorDisplaySeconds
        errorTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.errorMessage = nil
            self.errorTimer = nil
            self.settle()
        }
        settle()
    }

    private func clearError() {
        errorTimer?.cancel()
        errorTimer = nil
        errorMessage = nil
    }

    /// Sets the state to what is true now. Recording comes first, then an
    /// error on show, then dictations in line, then a model being prepared,
    /// then a missing permission.
    private func settle() {
        let next: DictationState
        if let since = capture?.startedAt {
            next = .recording(since: since)
        } else if let errorMessage {
            next = .error(errorMessage)
        } else if !line.isEmpty {
            next = .transcribing
        } else if let model = modelsPreparing.last {
            next = .preparingModel(model)
        } else if let missingPermission {
            next = .needsPermission(missingPermission)
        } else {
            next = .idle
        }
        if state != next { state = next }
    }

    /// The words to show for a failure.
    static func describe(_ error: Error) -> String {
        switch error {
        case TranscriptionError.modelNotReady(let reason), TranscriptionError.engineUnavailable(let reason),
             TranscriptionError.failed(let reason):
            return reason
        case TranscriptionError.cancelled, is CancellationError:
            return "The transcription was cancelled"
        default:
            return error.localizedDescription
        }
    }

    // MARK: - For tests

    /// Dictations the pipeline holds: the one recording and those in line.
    var dictationsInFlight: Int { (capture == nil ? 0 : 1) + line.count }

    // MARK: - Types

    /// The dictation being recorded.
    private struct Capture {
        var timer: StageTimer
        /// When the recorder started; nil while it waits for microphone access.
        var startedAt: Date?
        /// When the key went up; nil for a recording the recorder ends by
        /// itself (five minutes, or the input changed).
        var keyUpAt: Date?
    }

    /// A recording in line, with its own marks, so its timing survives the wait.
    private struct Dictation {
        let id = UUID()
        /// When the recording ended.
        let date: Date
        let clip: AudioClip
        let timer: StageTimer
        let transcription: Task<Transcription, Never>
    }

    /// What the service made of a clip.
    private struct Transcription: Sendable {
        let result: Result<TranscriptionResult, Error>
        /// The model that ran, or for a failure the model selected then.
        let model: ModelID
    }
}

// `AudioRecorder` is used from the main thread and calls its delegate there,
// which is what lets this main-actor class be its delegate.
extension DictationPipeline: @preconcurrency AudioRecorderDelegate {
    public func recordingDidStart() {
        guard capture != nil else {
            // Microphone access came after the key went up, and the recorder
            // started by itself: nobody is holding the key.
            recorder.cancelRecording()
            return
        }
        capture?.startedAt = Date()
        settle()
    }

    public func recordingDidFinish(clip: AudioClip) {
        guard var capture else { return }
        self.capture = nil
        level = 0
        // A recording the recorder ended by itself is timed from its end.
        capture.timer.mark(.keyUp, at: capture.keyUpAt ?? Date())
        enqueue(clip, timer: capture.timer)
    }

    public func recordingDidFail(error: String) {
        capture = nil
        level = 0
        Log.info("[PIPELINE] Recording failed: \(error)")
        show(error)
    }

    public func recordingDiscarded() {
        capture = nil
        level = 0
        settle()
    }
}
