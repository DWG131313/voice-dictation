import Foundation
import Observation

/// What the pipeline needs from the microphone recorder (`AudioRecorder`).
/// Every call and callback happens on the main thread.
public protocol Recording: AnyObject {
    var delegate: AudioRecorderDelegate? { get set }
    /// The peak (0...1) of each 50 ms slice of audio while recording, with
    /// the time it was captured, in seconds on the clock
    /// `ProcessInfo.systemUptime` reads (Task 24A).
    var onLevel: ((_ peak: Float, _ at: TimeInterval) -> Void)? { get set }
    /// When a recording's first audio arrived: at most once per recording,
    /// always before that recording's delegate call.
    var onFirstAudio: ((Date) -> Void)? { get set }
    /// The microphone to record from, by Core Audio UID; nil follows the
    /// system default, as does a UID whose device is not connected. Settings
    /// sets it (Task 24).
    var inputDeviceUID: String? { get set }
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

/// Puts text into the frontmost app, or on the clipboard.
public protocol Pasting {
    /// Puts `text` on the clipboard and pastes it into the frontmost app.
    /// Returns false when it could not paste; the text then stays on the
    /// clipboard.
    func paste(text: String) -> Bool
    /// Puts `text` on the clipboard and leaves it there, pasting nothing:
    /// the window's Copy, and a text that must not go to whatever app is in
    /// front (Task 19).
    func copy(text: String)
    /// The clipboard's change count (`NSPasteboard.changeCount`): it goes up
    /// each time anything is put on the clipboard, by this app or another,
    /// so two equal readings mean nothing was copied in between (Ruling T19-4).
    var clipboardChangeCount: Int { get }
    /// The app a paste would go to.
    var frontmostAppName: String? { get }
}

/// Runs each dictation from key press to paste. It records while the hotkey
/// is held, has the service transcribe each recording with the selected
/// model, in the order they were made, cleans the text up, and pastes it into
/// the frontmost app. Every dictation that is not cancelled, and whose text
/// is not empty, is reported once, through `onOutcome`. Use from the main
/// thread.
///
/// At most `maximumWaiting` recordings wait behind the one being transcribed.
/// When another arrives, the oldest waiting one is skipped: not pasted, and
/// reported as Failed with its audio (Review Focus 4). It normally never
/// reaches the engine; `enqueue` describes the one narrow exception. A
/// dictation whose text is back, waiting only for the paste before its own,
/// does not count as waiting.
///
/// Each text goes through, in order: `OutputFilter` (in the service, Ruling
/// P3), Danny's replacements, the cleaner and `CleanupGuard`, then the paste
/// (Ruling T21-1). Cleanup that changes more than fillers, punctuation and
/// case, fails, or is still running at `cleanupTimeLimit` gives way to the
/// raw text, with no error shown (Review Focus 3). One still running then is
/// left to finish, and if the guard accepts it, `onLateCleanup` keeps it
/// beside the transcript; nothing is pasted again.
@MainActor @Observable
public final class DictationPipeline {
    public static let maximumWaiting = 3
    /// The failure reported for a dictation skipped from a full line.
    public static let skippedFailure = "Skipped: too many dictations waiting"
    /// How long the paste waits for cleanup, in seconds; then the raw text
    /// pastes. The spec's starting value, to tune once it is measured.
    public static let cleanupTimeLimit: TimeInterval = 2.0
    /// A text with fewer words than this pastes without cleanup.
    public static let cleanupMinimumWords = 4

    /// What the app is doing. An error shows for `errorDisplaySeconds`, then
    /// the state returns to the true one.
    public private(set) var state: DictationState = .idle
    /// Each peak (0...1) heard while recording, with the time its slice was
    /// captured, for the indicator's line: once per slice, on the main
    /// thread, and nothing between recordings (Task 24A). A callback, not an
    /// observed value: a buffer's slices come together, and observation would
    /// report them as one.
    @ObservationIgnored public var onLevel: ((_ peak: Float, _ at: TimeInterval) -> Void)?
    /// Called once for every finished dictation: pasted, left on the
    /// clipboard, failed or skipped. A cancelled one has none, and so has
    /// one whose text came back empty, or that replacements emptied: it
    /// pastes nothing, and the log says so.
    @ObservationIgnored public var onOutcome: ((DictationOutcome) -> Void)?
    /// Called at most once for a dictation whose raw text pasted at the time
    /// limit, when its cleanup comes back afterwards and the guard accepts
    /// it: with the outcome's id, the cleaned text and the cleanup's seconds.
    /// A late result the guard rejects, or a failure, is dropped, and a
    /// cancelled dictation never gets here.
    @ObservationIgnored public var onLateCleanup: ((_ id: UUID, _ cleanedText: String, _ cleanupSeconds: Double) -> Void)?
    /// A permission dictation lacks ("Accessibility", "Microphone"). It shows
    /// as `.needsPermission` whenever there is nothing else to show.
    public var missingPermission: String? {
        didSet { settle() }
    }

    /// How long an error stays on show.
    @ObservationIgnored var errorDisplaySeconds: TimeInterval = 5
    /// How long the paste waits for cleanup; tests shorten it.
    @ObservationIgnored var cleanupLimitSeconds: TimeInterval = DictationPipeline.cleanupTimeLimit
    /// The marks of the dictation pasted last, as logged.
    @ObservationIgnored private(set) var lastTiming: StageTimer?

    @ObservationIgnored private let recorder: Recording
    @ObservationIgnored private let service: TranscriptionService
    @ObservationIgnored private let paster: Pasting
    /// Nil pastes every text as it is.
    @ObservationIgnored private let cleaner: TextCleaner?
    /// Read for each dictation: the app's "Clean up transcripts" setting.
    @ObservationIgnored private let cleanupEnabled: () -> Bool
    /// Read for each dictation: Danny's replacement rules and his words.
    @ObservationIgnored private let replacements: () -> [Replacement]
    @ObservationIgnored private let vocabulary: () -> [String]
    /// Read at each Paste last: the text to paste again (Ruling P4). The app
    /// points it at the store's latest transcript; the pipeline owns no store.
    @ObservationIgnored private let latestText: () -> String?

    /// The dictation being recorded, from key-down until its recording ends.
    @ObservationIgnored private var capture: Capture?
    /// The dictation this hold's recording became when the recorder ended it
    /// by itself while the key stayed down. `cancelHold` can still take it
    /// back until the hold ends.
    @ObservationIgnored private var dictationOfThisHold: UUID?
    /// Recordings handed to the service, oldest first. Of those not yet
    /// `isTranscribed`, the first is being transcribed and the rest wait.
    @ObservationIgnored private var line: [Dictation] = []
    /// The dictation being cleaned up, out of the line and not yet pasted.
    /// The next one in line is transcribed meanwhile, and pastes after it.
    @ObservationIgnored private var cleaning: Cleaning?
    /// Whether `finishLine` is running.
    @ObservationIgnored private var isFinishingLine = false
    @ObservationIgnored private var errorMessage: String?
    @ObservationIgnored private var errorTimer: Task<Void, Never>?
    /// Models being chosen, by name, latest last.
    @ObservationIgnored private var modelsPreparing: [String] = []

    /// `latestText` is what Paste last pastes; nil, the default, is nothing.
    public init(recorder: Recording, service: TranscriptionService, paster: Pasting,
                cleaner: TextCleaner?, replacements: @escaping () -> [Replacement], vocabulary: @escaping () -> [String],
                cleanupEnabled: @escaping () -> Bool = { true }, latestText: @escaping () -> String? = { nil }) {
        self.recorder = recorder
        self.service = service
        self.paster = paster
        self.cleaner = cleaner
        self.cleanupEnabled = cleanupEnabled
        self.replacements = replacements
        self.vocabulary = vocabulary
        self.latestText = latestText
        recorder.delegate = self
        recorder.onLevel = { [weak self] peak, time in
            guard let self, self.capture != nil else { return }
            self.onLevel?(peak, time)
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
        dictationOfThisHold = nil
        var timer = StageTimer()
        timer.mark(.keyDown)
        capture = Capture(timer: timer)
        // A new dictation replaces whatever went wrong before it.
        clearError()
        // The recorder calls back before returning, unless it is asking for
        // microphone access first.
        recorder.startRecording()
        settle()
        // Ruling T21-2: the cleanup model loads while Danny speaks, since a
        // cold one outlasts the time limit. Off the main thread and after
        // the recorder has started, it adds nothing to keyDown→firstAudio.
        prewarmCleanup()
    }

    public func hotkeyUp() {
        // The hold is over; whatever it made is no longer the hotkey's to cancel.
        dictationOfThisHold = nil
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

    /// The hotkey's own cancel, for this hold only: a key pressed while the
    /// hotkey is held, the hotkey used as a modifier (Globe+Right Arrow is
    /// End). It cancels this hold's dictation and nothing else. That is the
    /// recording under way or, when the recorder ended it by itself while
    /// the key stayed down (five minutes, or the input changed), the
    /// dictation it became, wherever that is in line, or while it is cleaned
    /// up. When the recorder failed to start or threw the recording away, the
    /// hold has no dictation and nothing is cancelled. Unlike `cancel()`,
    /// Escape's cancel, it never touches a dictation made before this hold.
    /// The cancelled dictation leaves no trace, as with `cancel()`.
    public func cancelHold() {
        cancelThisHold(because: "a key was pressed while the hotkey was held")
    }

    /// The hotkey was tapped, not held, with double-tap dictation on: maybe
    /// the first tap of a double tap, never a dictation. The recording the press
    /// started is thrown away as `cancelHold()` would, leaving no trace, and
    /// nothing made before it is touched.
    public func discardTap() {
        cancelThisHold(because: "the hotkey was tapped, not held")
    }

    private func cancelThisHold(because reason: String) {
        if capture != nil {
            Log.info("[PIPELINE] Cancelled the recording: \(reason)")
            cancelCapture()
            return
        }
        guard let id = dictationOfThisHold else { return }
        dictationOfThisHold = nil
        if cleaning?.id == id {
            cancelCleanup()
        } else {
            // Gone from the line means it has already finished, or was skipped.
            guard let index = line.firstIndex(where: { $0.id == id }) else { return }
            line.remove(at: index).transcription.cancel()
        }
        Log.info("[PIPELINE] Cancelled the dictation the recorder stopped while the hotkey was held")
        settle()
    }

    /// Escape's cancel (Task 23): Escape while the app is recording,
    /// transcribing or cleaning up, locked by a double tap or not. It cancels what
    /// the pipeline is doing, not just the current hold's dictation. While
    /// recording, it cancels the recording only, so dictations already in
    /// line still paste. Otherwise it cancels the dictation being cleaned up
    /// and every dictation in line. A key pressed with the hotkey held uses
    /// `cancelHold()` instead, which never reaches a dictation made before
    /// the current hold. A cancelled dictation pastes nothing, reports no
    /// outcome, not even a late cleanup, and leaves no audio behind. A
    /// dictation already pasted is not cancelled: its late cleanup, if any,
    /// is still kept.
    public func cancel() {
        if capture != nil {
            cancelCapture()
            return
        }
        guard !line.isEmpty || cleaning != nil else { return }
        let cancelled = line
        line.removeAll()
        cancelled.forEach { $0.transcription.cancel() }
        let wasCleaning = cancelCleanup()
        Log.info("[PIPELINE] Cancelled \(cancelled.count) dictation(s) in line"
                 + (wasCleaning ? " and the one being cleaned up" : ""))
        settle()
    }

    /// Stops the cleanup under way, if any: its dictation pastes nothing and
    /// is not reported (`clean` sees it gone). Returns whether there was one.
    @discardableResult
    private func cancelCleanup() -> Bool {
        guard let cleaning else { return false }
        self.cleaning = nil
        cleaning.work.cancel()
        cleaning.wait.cancel()
        return true
    }

    /// Ends the recording under way and throws it away.
    private func cancelCapture() {
        guard let capture else { return }
        self.capture = nil
        if capture.startedAt != nil { recorder.cancelRecording() }
        settle()
    }

    /// Pastes the latest text again, as `latestText` gives it (Ruling P4):
    /// the store's latest transcript, as it reads now, edits included, and
    /// never a failed dictation's empty text. From the menu and from
    /// Control-Option-V. It is no dictation: nothing is reported.
    public func pasteLast() {
        guard let text = textToPasteLast else {
            Log.info("[PIPELINE] Paste last: nothing to paste")
            return
        }
        if !paster.paste(text: text) {
            Log.info("[PIPELINE] Paste last: could not paste, text left on the clipboard")
        }
    }

    /// Whether `pasteLast` has a text to paste; the menu item is off without.
    public var canPasteLast: Bool { textToPasteLast != nil }

    private var textToPasteLast: String? {
        guard let text = latestText(), !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Choosing a model

    /// Makes `id` the model dictations use, downloading it first when asked.
    /// Shows `.preparingModel(name)` meanwhile, whenever nothing more urgent
    /// is showing. A failure is shown as an error and rethrown; the selection
    /// is then unchanged.
    public func selectModel(_ id: ModelID, named name: String, downloadingFirst: Bool = false) async throws {
        do {
            try await whilePreparing(name) {
                if downloadingFirst {
                    Log.info("[PIPELINE] Downloading \(id.storageKey)")
                    try await service.download(id) { _ in }
                }
                try await service.select(id)
                Log.info("[PIPELINE] Dictating with \(id.storageKey)")
            }
        } catch {
            let reason = Self.describe(error)
            Log.info("[PIPELINE] Could not switch to \(id.storageKey): \(reason)")
            show(reason)
            throw error
        }
    }

    /// Shows `.preparingModel(name)` while `work` runs, whenever nothing
    /// more urgent is showing. For a model choice that downloads elsewhere.
    public func whilePreparing<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
        modelsPreparing.append(name)
        settle()
        defer {
            if let index = modelsPreparing.lastIndex(of: name) { modelsPreparing.remove(at: index) }
            settle()
        }
        return try await work()
    }

    /// Shows why a model choice failed, as an error for a few seconds.
    public func showModelFailure(_ reason: String) {
        Log.info("[PIPELINE] Model choice failed: \(reason)")
        show(reason)
    }

    // MARK: - The line

    /// Hands a finished recording to the service. It goes in line behind
    /// the dictations already there, and a full line skips its oldest
    /// waiting dictation. Returns the new dictation's id.
    private func enqueue(_ clip: AudioClip, timer: StageTimer) -> UUID {
        let service = self.service
        let words = vocabulary()
        let id = UUID()
        // Each call goes to the service now, so the service sees every
        // dictation waiting and keeps re-transcriptions behind them.
        let transcription = Task { [weak self] () -> Transcription in
            let result: Result<TranscriptionResult, Error>
            do {
                result = .success(try await service.transcribe(clip, vocabulary: words))
            } catch {
                result = .failure(error)
            }
            // Back on the main actor: from now on it no longer counts as waiting.
            self?.markTranscribed(id)
            switch result {
            case .success(let value): return Transcription(result: result, model: value.model)
            case .failure: return Transcription(result: result, model: await service.selected)
            }
        }
        line.append(Dictation(id: id, date: Date(), clip: clip, timer: timer, transcription: transcription))
        // Too many waiting: skip the oldest waiting one (Review Focus 4).
        // Only dictations whose call to the service has not returned count:
        // the first is being transcribed, the rest wait. Those before it
        // have their text and wait only for a paste, which a cleanup can
        // hold back for `cleanupTimeLimit`. A recording that ends between
        // the service returning the first one's text and its task marking
        // it still counts that one, so it may skip a dictation already in
        // the engine. The window is one main-actor hop, so it is kept
        // (ruling, Task 9 review; Task 21's review moved the count to the mark).
        if let first = line.firstIndex(where: { !$0.isTranscribed }),
           line.count - (first + 1) > Self.maximumWaiting {
            skip(line.remove(at: first + 1))
        }
        settle()
        if !isFinishingLine {
            isFinishingLine = true
            Task { await finishLine() }
        }
        return id
    }

    /// Its call to the service has returned. Gone means cancelled or skipped.
    private func markTranscribed(_ id: UUID) {
        guard let index = line.firstIndex(where: { $0.id == id }) else { return }
        line[index].isTranscribed = true
    }

    /// Finishes the dictations in line one at a time, oldest first, so they
    /// paste in the order they were made. While one is cleaned up, the next
    /// is transcribed, and waits for that paste.
    private func finishLine() async {
        while let dictation = line.first {
            let transcription = await dictation.transcription.value
            // Gone means cancelled while it was transcribing.
            guard line.first?.id == dictation.id else { continue }
            line.removeFirst()
            await finish(dictation, transcription)
        }
        isFinishingLine = false
        settle()
    }

    private func finish(_ dictation: Dictation, _ transcription: Transcription) async {
        var timer = dictation.timer
        timer.mark(.textReady)
        switch transcription.result {
        case .success(let result):
            guard !result.text.isEmpty else {
                Log.info("[PIPELINE] \(result.model.storageKey) heard nothing; nothing pasted")
                return
            }
            // The service's text has been through OutputFilter (Ruling P3).
            let rawText = applyingReplacements(to: result.text)
            // A rule can empty the text: then there is nothing to paste or keep.
            guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Log.info("[PIPELINE] \(result.model.storageKey): replacements left no text; nothing pasted")
                return
            }
            var cleanedText: String?
            var cleanupSeconds: Double?
            var stillCleaning: Task<CleanerRun, Error>?
            if let cleaner = cleanerToRun(on: rawText) {
                switch await clean(rawText, with: cleaner, for: dictation.id) {
                case .cancelled:
                    return
                case .accepted(let run):
                    cleanedText = run.text
                    cleanupSeconds = run.seconds
                case .rawText:
                    break
                case .timedOut(let work):
                    stillCleaning = work
                }
                timer.mark(.cleaned)
            }
            let text = cleanedText ?? rawText
            let appName = paster.frontmostAppName
            let pasted = paster.paste(text: text)
            timer.mark(.pasted)
            lastTiming = timer
            Log.info("[TIMING] \(timer.summary)")
            let cleanup = cleanupSeconds.map { ", cleaned up in \(String(format: "%.2f", $0)) s" } ?? ""
            Log.info("[PIPELINE] \(pasted ? "Pasted" : "Could not paste, left on the clipboard:") \(text.count) chars from \(result.model.storageKey) in \(String(format: "%.2f", result.elapsed)) s\(cleanup)")
            onOutcome?(DictationOutcome(
                id: dictation.id, date: dictation.date, clip: dictation.clip,
                rawText: rawText, cleanedText: cleanedText, text: text, model: result.model,
                transcribeSeconds: result.elapsed, cleanupSeconds: cleanupSeconds,
                appName: appName, status: pasted ? .pasted : .copied
            ))
            if let stillCleaning { keepLateCleanup(stillCleaning, of: rawText, for: dictation.id) }
            prewarmCleanup()
        case .failure(let error):
            let reason = Self.describe(error)
            Log.info("[PIPELINE] Transcription with \(transcription.model.storageKey) failed: \(reason)")
            report(failed: dictation, model: transcription.model, reason: reason)
            show(reason)
        }
    }

    /// Reports a dictation taken out of line as Failed, keeping its audio,
    /// and cancels its call to the service. That call is normally still
    /// waiting at the service; `enqueue` describes the moment when it is not.
    private func skip(_ dictation: Dictation) {
        dictation.transcription.cancel()
        Log.info("[PIPELINE] More than \(Self.maximumWaiting) dictations waiting; skipped the oldest")
        show(Self.skippedFailure)
        Task {
            // The cancelled call ends at once unless its clip is already in
            // the engine, and says which model ran or was selected.
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

    // MARK: - Cleanup

    /// Readies the cleaner for the next dictation, while cleanup is on and
    /// the cleaner can run: at launch (the app), when the hotkey goes down
    /// (Ruling T21-2) and after each pasted dictation. The check and the
    /// prewarm run off the main thread, which also runs the event tap.
    public func prewarmCleanup() {
        guard let cleaner, cleanupEnabled() else { return }
        Task.detached(priority: .utility) {
            guard cleaner.isAvailable else { return }
            cleaner.prewarm()
        }
    }

    /// The second step of the order (Ruling T21-1): Danny's replacements,
    /// on the service's text. What it returns is the dictation's raw text,
    /// which the cleaner gets and the guard compares against.
    private func applyingReplacements(to text: String) -> String {
        Replacements.apply(replacements(), to: text)
    }

    /// The cleaner, when `text` is to be cleaned up: cleanup is on, the text
    /// has at least `cleanupMinimumWords` words, and the cleaner can run.
    private func cleanerToRun(on text: String) -> TextCleaner? {
        guard let cleaner, cleanupEnabled(),
              CleanupGuard.tokens(text).count >= Self.cleanupMinimumWords,
              cleaner.isAvailable else { return nil }
        return cleaner
    }

    /// Cleans `raw` up, showing `.cleaning`, and waits at most
    /// `cleanupLimitSeconds` for it. Only an accepted cleanup in time gives
    /// text to paste; an error, a rejection or the time limit gives the raw
    /// text, and none of them shows an error (Review Focus 3).
    private func clean(_ raw: String, with cleaner: TextCleaner, for id: UUID) async -> CleanupEnd {
        let work = Task { try await CleanerRun.run(cleaner, on: raw) }
        let limit = cleanupLimitSeconds
        let wait = Task { await CleanerRun.wait(for: work, upTo: limit) }
        cleaning = Cleaning(id: id, work: work, wait: wait)
        settle()
        let waited = await wait.value
        // Gone means cancelled while it was cleaned up (`cancelCleanup`),
        // whatever the wait saw first.
        guard cleaning?.id == id else { return .cancelled }
        cleaning = nil
        settle()
        switch waited {
        case .finished(.success(let run)):
            guard CleanupGuard.accepts(raw: raw, cleaned: run.text) else {
                Log.info("[PIPELINE] Cleanup changed more than fillers, punctuation and case; pasting the raw text")
                return .rawText
            }
            return .accepted(run)
        case .finished(.failure(let error)):
            Log.info("[PIPELINE] Cleanup failed (\(error.localizedDescription)); pasting the raw text")
            return .rawText
        case .timedOut:
            Log.info("[PIPELINE] Cleanup took longer than \(String(format: "%g", limit)) s; pasting the raw text")
            return .timedOut(work)
        case .cancelled:
            // Only `cancelCleanup` ends the wait early, and it clears `cleaning` first.
            return .cancelled
        }
    }

    /// Lets a cleanup the time limit cut short finish. If the guard accepts
    /// its text, `onLateCleanup` gets it, once; a rejected or failed result
    /// is dropped. Its dictation has pasted, so nothing is pasted again.
    private func keepLateCleanup(_ work: Task<CleanerRun, Error>, of raw: String, for id: UUID) {
        Task { [weak self] in
            guard let run = try? await work.value else {
                Log.info("[PIPELINE] The late cleanup failed; the raw text stays")
                return
            }
            guard CleanupGuard.accepts(raw: raw, cleaned: run.text) else {
                Log.info("[PIPELINE] The late cleanup changed more than fillers, punctuation and case; dropped")
                return
            }
            Log.info("[PIPELINE] Cleanup came back after \(String(format: "%.2f", run.seconds)) s; kept beside the pasted text")
            self?.onLateCleanup?(id, run.text, run.seconds)
        }
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
    /// error on show, then a cleanup under way (the dictation that pastes
    /// next), then dictations in line, then a model being prepared, then a
    /// missing permission.
    private func settle() {
        let next: DictationState
        if let since = capture?.startedAt {
            next = .recording(since: since)
        } else if let errorMessage {
            next = .error(errorMessage)
        } else if cleaning != nil {
            next = .cleaning
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

    /// The words to show for a failure; the window says a re-transcription's
    /// failure in the same words.
    public static func describe(_ error: Error) -> String {
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

    /// Dictations the pipeline holds: the one recording, the one being
    /// cleaned up and those in line. A pasted dictation whose cleanup runs on
    /// for a late result is not one of them.
    var dictationsInFlight: Int { (capture == nil ? 0 : 1) + (cleaning == nil ? 0 : 1) + line.count }

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
        let id: UUID
        /// When the recording ended.
        let date: Date
        let clip: AudioClip
        let timer: StageTimer
        let transcription: Task<Transcription, Never>
        /// Set on the main actor once its call to the service has returned.
        var isTranscribed = false
    }

    /// What the service made of a clip.
    private struct Transcription: Sendable {
        let result: Result<TranscriptionResult, Error>
        /// The model that ran, or for a failure the model selected then.
        let model: ModelID
    }

    /// The dictation being cleaned up.
    private struct Cleaning {
        let id: UUID
        /// The cleaner's run. Past the time limit it runs on, for a late result.
        let work: Task<CleanerRun, Error>
        /// Waits for `work` up to the time limit; `cancelCleanup` ends it at once.
        let wait: Task<CleanerRun.Waited, Never>
    }

    /// How a dictation's cleanup ended, for its paste.
    private enum CleanupEnd {
        /// The guard accepted it in time: its text pastes.
        case accepted(CleanerRun)
        /// Rejected, or failed: the raw text pastes.
        case rawText
        /// Still running at the time limit: the raw text pastes, and a late
        /// result may follow.
        case timedOut(Task<CleanerRun, Error>)
        /// Cancelled with its dictation: nothing pastes.
        case cancelled
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
        // A recording the recorder ended by itself is timed from its end.
        capture.timer.mark(.keyUp, at: capture.keyUpAt ?? Date())
        let id = enqueue(clip, timer: capture.timer)
        // Ended by the recorder while the key is still down: until the key
        // goes up, a key pressed with it cancels this dictation.
        if capture.keyUpAt == nil { dictationOfThisHold = id }
    }

    public func recordingDidFail(error: String) {
        capture = nil
        Log.info("[PIPELINE] Recording failed: \(error)")
        show(error)
    }

    public func recordingDiscarded() {
        capture = nil
        settle()
    }
}
