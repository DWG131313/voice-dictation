import AudioToolbox
import AVFoundation
import Cocoa
import CoreAudio
import ObjCHelpers

public protocol AudioRecorderDelegate: AnyObject {
    func recordingDidStart()
    func recordingDidFinish(clip: AudioClip)
    func recordingDidFail(error: String)
    func recordingDiscarded()
}

/// What happens to a finished recording.
public enum RecordingVerdict {
    case keep, tooShort, silent
}

/// Records the microphone into memory as 16 kHz mono samples.
///
/// The capture engine is built ahead of time (`prepare()`) so the first
/// syllable is not lost, but it only runs while recording: a running input
/// lights the microphone indicator. Use from the main thread.
public class AudioRecorder {
    /// Recordings shorter than this are accidental taps.
    public static let minimumDuration: TimeInterval = 0.5
    /// Recordings whose peak never reaches this are treated as silence and
    /// discarded. Whisper hallucinates words like "you" or "Thank you." on
    /// silent input, and a muted or absent mic would otherwise paste those.
    /// -40 dBFS is far below any audible speech.
    public static let silenceThreshold: Float = 0.01
    /// How long a stretch of audio each level covers: one vertex of the
    /// indicator's line, `LevelLine.interval`. That type lives in
    /// VoiceDictationUI, which this library cannot see, so a test there keeps
    /// the two equal (Task 24A).
    static let levelSlice: TimeInterval = 0.05

    /// Too short wins over silent, so an accidental tap reads as a tap.
    public static func verdict(duration: TimeInterval, peak: Float) -> RecordingVerdict {
        if duration < minimumDuration { return .tooShort }
        if peak < silenceThreshold { return .silent }
        return .keep
    }

    /// Whether an engine prepared for one input format must be rebuilt for
    /// another (AirPods connected since, say). Its tap and converter only
    /// fit the old format, so it would record nothing.
    static func needsRebuild(prepared: AVAudioFormat?, current: AVAudioFormat) -> Bool {
        guard let prepared else { return true }
        return prepared.sampleRate != current.sampleRate || prepared.channelCount != current.channelCount
    }

    /// The most engine rebuilds that configuration changes may cause between
    /// two recordings. If preparing an engine ever changed the device's format
    /// itself, each rebuild would cause the next one.
    static let idleRebuildLimit = 2

    /// Whether a configuration change while idle should rebuild the engine:
    /// only when the input format moved, and only below the limit. An engine
    /// that stopped itself re-prepares on `start()`, and the key-down check
    /// still catches anything skipped here.
    static func shouldRebuildWhenIdle(prepared: AVAudioFormat?, current: AVAudioFormat, rebuildsInARow: Int) -> Bool {
        rebuildsInARow < idleRebuildLimit && needsRebuild(prepared: prepared, current: current)
    }

    /// Counts the rebuilds idle configuration changes cause until the next recording.
    struct IdleRebuilds {
        private(set) var inARow = 0

        /// Asks `shouldRebuildWhenIdle` about each of the input's current
        /// formats, and counts a yes.
        mutating func allow(prepared: AVAudioFormat?, current: [AVAudioFormat]) -> Bool {
            let rebuild = current.contains {
                AudioRecorder.shouldRebuildWhenIdle(prepared: prepared, current: $0, rebuildsInARow: inARow)
            }
            if rebuild { inARow += 1 }
            return rebuild
        }

        mutating func recordingEnded() { inARow = 0 }
    }

    public weak var delegate: AudioRecorderDelegate?
    /// Called at most once per recording, on the main queue, with the time the
    /// first microphone buffer arrived. Always before that recording's
    /// delegate call.
    public var onFirstAudio: ((Date) -> Void)?
    /// The peak (0...1) of each `levelSlice` of the recording, with the time
    /// its first sample was captured (Task 24A). Called on the main queue, once
    /// per slice, a buffer's slices in one go. The time is in seconds on the
    /// mach clock `ProcessInfo.systemUptime` reads, from the buffer's host
    /// time, so the indicator's line, drawn on that clock, places each slice
    /// where it was heard however the buffers bunch on their way here.
    public var onLevel: ((_ peak: Float, _ at: TimeInterval) -> Void)?
    /// The Core Audio UID of the microphone to record from; nil follows the
    /// system default, as does a UID that matches no connected device.
    /// Setting it prepares again (after the current recording, if one is running).
    public var inputDeviceUID: String? {
        didSet { if inputDeviceUID != oldValue { prepare() } }
    }
    /// Read at each start and stop: whether the start and stop sounds play
    /// ("Start and stop sounds" in Settings).
    private let soundsEnabled: () -> Bool

    /// Safety net: if the key-up event is ever lost, stop on our own rather
    /// than recording forever.
    public var maximumDuration: TimeInterval = 300

    public private(set) var isRecording = false

    /// An engine built for one input format, and the converter from that
    /// format to the clip's. Each one serves a single recording.
    private struct PreparedInput {
        let engine: AVAudioEngine
        let converter: AVAudioConverter
        let format: AVAudioFormat
        /// The system's default input when the engine was built.
        let defaultDevice: AudioDeviceID?
        /// The chosen microphone, set on the engine's input unit; nil when the
        /// engine follows the system default.
        let device: AudioDeviceID?
    }

    private var prepared: PreparedInput?
    private var tapInstalled = false
    private var configChangeObserver: NSObjectProtocol?
    private var idleRebuilds = IdleRebuilds()

    private var recordingStartTime: Date?
    private var maxDurationTimer: Timer?
    /// Numbers recordings, so a late callback from one never reaches the next.
    private var recordingID = 0
    private var firstAudioDelivered = false
    /// Whether the log has said that buffers came without a host time.
    private var loggedMissingHostTime = false

    /// What the tap thread hands over. Only touched under `captureLock`.
    private struct Capture {
        var recordingID = 0
        var isOpen = false
        var samples: [Float] = []
        var peak: Float = 0
        var firstAudio: Date?
    }

    private let captureLock = NSLock()
    private var capture = Capture()

    /// The system's Tink and Pop, played through System Sound Services
    /// (Task 24): its play call returns in well under a millisecond, where
    /// `NSSound.play()` held its caller 16 to 73 ms (measured on this Mac).
    private let tickOnSound = SystemSound(named: "Tink")
    private let tickOffSound = SystemSound(named: "Pop")

    /// `inputDeviceUID` is the microphone to record from (nil: the system
    /// default); `soundsEnabled` is read at each start and stop.
    public init(inputDeviceUID: String? = nil, soundsEnabled: @escaping () -> Bool = { true }) {
        self.inputDeviceUID = inputDeviceUID
        self.soundsEnabled = soundsEnabled
        observeDefaultInputDevice()
        observeDevices()
    }

    deinit {
        maxDurationTimer?.invalidate()
        discardEngine()
    }

    /// Builds a fresh engine and converter for the current input without
    /// starting them, so the next recording starts at once. Called at launch,
    /// after every recording, and when the input changes. Does nothing while
    /// recording, or until microphone access is granted, so the permission
    /// prompt only ever follows a key press.
    public func prepare() {
        guard !isRecording, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        do {
            try buildInput()
        } catch {
            Log.info("[AUDIO] Not prepared: \(error.localizedDescription)")
        }
    }

    public func startRecording() {
        guard !isRecording else {
            Log.info("[AUDIO] startRecording ignored — already recording")
            return
        }

        // Check microphone permission before accessing audio hardware
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.startRecording()
                    } else {
                        self?.delegate?.recordingDidFail(error: "Microphone access denied. Enable in System Settings > Privacy & Security > Microphone.")
                    }
                }
            }
            return
        default:
            delegate?.recordingDidFail(error: "Microphone access denied. Enable in System Settings > Privacy & Security > Microphone.")
            return
        }

        let input: PreparedInput
        do {
            input = try inputForRecording()
        } catch {
            delegate?.recordingDidFail(error: error.localizedDescription)
            return
        }

        // Start clean before the tap can deliver anything.
        recordingID += 1
        let id = recordingID
        firstAudioDelivered = false
        captureLock.withLock { capture = Capture(recordingID: id, isOpen: true) }

        // installTap raises an Objective-C exception (not a Swift error) when
        // mic permission is denied or the format is invalid.
        let converter = input.converter
        do {
            try ObjCExceptionCatcher.`try`({
                input.engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: input.format) { [weak self] buffer, when in
                    self?.receive(buffer, at: when, converter: converter, recordingID: id)
                }
            })
            tapInstalled = true
        } catch {
            discardEngine()
            delegate?.recordingDidFail(error: "Cannot access microphone: \(error.localizedDescription)")
            return
        }

        // The start sound plays right after the engine has started (Task 24,
        // Ruling T24-1), never before it and never when it fails. The sound
        // server plays it and the call returns in about 0.1 ms, so first audio
        // is not held up. Through speakers it is heard by the microphone: it
        // overlaps the first ~0.5 s of the recording (Tink lasts 0.56 s); with
        // headphones it does not. Whisper suppresses non-speech, and the
        // silence check only looks at the peak of the whole recording.
        do {
            try Self.startEngine({ try input.engine.start() },
                                 thenPlayStartSound: { [weak self] in
                                     guard let self, self.soundsEnabled() else { return }
                                     self.tickOnSound?.play()
                                 })
        } catch {
            Log.info("[AUDIO] Engine did not start: \(error.localizedDescription)")
            discardEngine()
            delegate?.recordingDidFail(error: "Microphone in use by another app")
            return
        }

        isRecording = true
        recordingStartTime = Date()
        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maximumDuration, repeats: false) { [weak self] _ in
            Log.info("[AUDIO] Maximum recording duration reached — stopping automatically")
            self?.stopRecording()
        }
        delegate?.recordingDidStart()
    }

    /// Starts the engine, then plays the start sound, only if it started. A
    /// recording that did not start gets no tick.
    static func startEngine(_ start: () throws -> Void, thenPlayStartSound play: () -> Void) throws {
        try start()
        play()
    }

    /// Ends the recording and calls the delegate before returning.
    public func stopRecording() {
        guard isRecording else { return }
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let captured = endCapture()
        // Only once the capture has stopped, so the stop sound is not recorded.
        if soundsEnabled() { tickOffSound?.play() }

        switch Self.verdict(duration: duration, peak: captured.peak) {
        case .tooShort:
            delegate?.recordingDiscarded()
        case .silent:
            Log.info("[AUDIO] Recording of \(String(format: "%.1f", duration))s was silent (peak \(captured.peak)) — discarding")
            delegate?.recordingDiscarded()
        case .keep:
            let clip = AudioClip(samples: captured.samples)
            Log.info("[AUDIO] Recording finished: \(String(format: "%.1f", duration))s (\(String(format: "%.1f", clip.duration))s of audio), peak \(String(format: "%.2f", captured.peak))")
            delegate?.recordingDidFinish(clip: clip)
        }
        prepare()
    }

    public func cancelRecording() {
        guard isRecording else { return }
        _ = endCapture()
        delegate?.recordingDiscarded()
        prepare()
    }

    // MARK: - Capture

    /// The prepared input, rebuilt first if nothing is prepared or the input
    /// format moved since.
    private func inputForRecording() throws -> PreparedInput {
        if let input = prepared {
            let stale = Self.currentFormats(of: input.engine).contains {
                Self.needsRebuild(prepared: input.format, current: $0)
            }
            if !stale { return input }
            Log.info("[AUDIO] Input changed since it was prepared — rebuilding")
        }
        return try buildInput()
    }

    /// Both of the input node's formats: the input side is the hardware's,
    /// the output side is what the tap gets. After a configuration change the
    /// output side can keep its old format.
    private static func currentFormats(of engine: AVAudioEngine) -> [AVAudioFormat] {
        [engine.inputNode.outputFormat(forBus: 0), engine.inputNode.inputFormat(forBus: 0)]
    }

    /// Replaces the prepared input with a fresh engine on the chosen
    /// microphone. Prepares the engine but never starts it.
    @discardableResult
    private func buildInput() throws -> PreparedInput {
        discardEngine()
        // Read before the engine picks its device: if the default changes in
        // between, the listener rebuilds once more rather than not at all.
        let defaultDevice = AudioDevices.defaultInputDevice()
        let engine = AVAudioEngine()
        // On the input unit before anything reads its format or prepares it.
        let device = selectMicrophone(on: engine.inputNode)

        // 0 channels means no mic access or no device
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw RecorderError("No microphone available. Check System Settings > Privacy & Security > Microphone.")
        }
        guard let converter = AVAudioConverter(from: format, to: AudioClip.audioFormat) else {
            throw RecorderError("Unsupported microphone format (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch)")
        }
        do {
            try ObjCExceptionCatcher.`try`({ engine.prepare() })
        } catch {
            throw RecorderError("Cannot access microphone: \(error.localizedDescription)")
        }

        let input = PreparedInput(engine: engine, converter: converter, format: format, defaultDevice: defaultDevice,
                                  device: device)
        prepared = input
        observeConfigurationChanges(of: engine)
        Log.info("[AUDIO] Prepared input: channels=\(format.channelCount) sampleRate=\(format.sampleRate)")
        return input
    }

    /// Stops and releases the engine; stopping turns the microphone off.
    private func discardEngine() {
        removeConfigObserver()
        if let engine = prepared?.engine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        tapInstalled = false
        prepared = nil
    }

    /// Runs on the tap's thread for every buffer: converts it, adds it to the
    /// capture, cuts it into the line's slices (Task 24A) and hands them to
    /// the main queue in one hop. The samples are read where the converter
    /// put them, so the slices' array takes the place of the copy of the
    /// samples this made before: no more allocations than one level a buffer.
    private func receive(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime, converter: AVAudioConverter,
                         recordingID id: Int) {
        let arrived = Date()
        let start = Self.captureTime(of: when, duration: Double(buffer.frameLength) / buffer.format.sampleRate,
                                     arrivedAt: AVAudioTime.seconds(forHostTime: mach_absolute_time()))
        let taken: (isFirst: Bool, slices: [(peak: Float, at: TimeInterval)])? =
            Self.withSamples(of: Self.convert(buffer, with: converter)) { samples in
                let slices = Self.slicePeaks(samples, sampleRate: AudioClip.sampleRate, startTime: start)
                let level = slices.reduce(0) { max($0, $1.peak) }
                let isFirst: Bool? = captureLock.withLock {
                    guard capture.isOpen, capture.recordingID == id else { return nil }
                    capture.samples.append(contentsOf: samples)
                    capture.peak = max(capture.peak, level)
                    guard capture.firstAudio == nil else { return false }
                    capture.firstAudio = arrived
                    return true
                }
                return isFirst.map { ($0, slices) }
            }
        guard let taken else { return }
        let timedByArrival = !when.isHostTimeValid
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording, self.recordingID == id else { return }
            if taken.isFirst { self.deliverFirstAudio() }
            if timedByArrival, !self.loggedMissingHostTime {
                self.loggedMissingHostTime = true
                Log.info("[AUDIO] Microphone buffers came without a host time — the volume line times them by their arrival")
            }
            for slice in taken.slices { self.onLevel?(slice.peak, slice.at) }
        }
    }

    /// The peak (0...1) of each `slice` of `samples`, oldest first, stamped
    /// with the time its first sample was captured: `startTime`, then one
    /// `slice` later for each after it. A buffer that is not a whole number of
    /// slices ends with a shorter one. Pure, and it allocates nothing but the
    /// array it returns, so the tap's thread can call it.
    static func slicePeaks(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, startTime: TimeInterval,
                           slice: TimeInterval = levelSlice) -> [(peak: Float, at: TimeInterval)] {
        guard sampleRate > 0, slice > 0, !samples.isEmpty else { return [] }
        let length = max(1, Int((slice * sampleRate).rounded()))
        var peaks: [(peak: Float, at: TimeInterval)] = []
        peaks.reserveCapacity((samples.count + length - 1) / length)
        for first in stride(from: 0, to: samples.count, by: length) {
            let peak = samples[first..<min(first + length, samples.count)].reduce(0) { max($0, abs($1)) }
            peaks.append((peak: peak, at: startTime + Double(first) / sampleRate))
        }
        return peaks
    }

    /// When a tap buffer's first sample was captured, in seconds on the mach
    /// clock (Task 24A). The tap's `when` is "the time at which the buffer was
    /// captured" (AVAudioNode.h), and its host time counts mach_absolute_time()
    /// ticks (AVAudioTime.h); `seconds(forHostTime:)` turns those into the
    /// seconds `ProcessInfo.systemUptime` reads. A buffer whose host time is
    /// not valid is timed by when it `arrived`, on the same clock, less its
    /// `duration`: its slices then end as it arrived, rather than run ahead of
    /// the line, which is drawn at the present.
    static func captureTime(of when: AVAudioTime, duration: TimeInterval, arrivedAt arrived: TimeInterval) -> TimeInterval {
        when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : arrived - duration
    }

    /// Converts one tap buffer to 16 kHz mono, or gives nil if the converter
    /// fails. The converter keeps its resampling state between buffers, so
    /// they join seamlessly.
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * AudioClip.sampleRate / buffer.format.sampleRate).rounded(.up)
        )
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else { return nil }
        return output
    }

    /// Calls `body` with the samples of a buffer `convert` made, read where
    /// they are while the buffer lives; with none for nil.
    static func withSamples<Result>(of buffer: AVAudioPCMBuffer?, _ body: (UnsafeBufferPointer<Float>) -> Result) -> Result {
        withExtendedLifetime(buffer) {
            guard let buffer, let channel = buffer.floatChannelData?[0] else {
                return body(UnsafeBufferPointer(start: nil, count: 0))
            }
            return body(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
    }

    private func deliverFirstAudio() {
        guard !firstAudioDelivered, let time = captureLock.withLock({ capture.firstAudio }) else { return }
        firstAudioDelivered = true
        onFirstAudio?(time)
    }

    /// Stops the engine and takes what was captured. A first-audio time still
    /// on its way to the main queue is delivered now, so it can never land
    /// after this recording's delegate call.
    private func endCapture() -> Capture {
        isRecording = false
        recordingStartTime = nil
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
        idleRebuilds.recordingEnded()
        discardEngine()
        let captured = captureLock.withLock {
            let captured = capture
            capture = Capture()
            return captured
        }
        if !firstAudioDelivered, let time = captured.firstAudio {
            firstAudioDelivered = true
            onFirstAudio?(time)
        }
        return captured
    }

    // MARK: - Input changes

    /// The engine stops itself when the input hardware's format changes. The
    /// notification arrives on the engine's internal queue, and tearing the
    /// engine down from there can deadlock (AVAudioEngine.h), so the work
    /// happens on the main queue.
    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        removeConfigObserver()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self, weak engine] _ in
            DispatchQueue.main.async { [weak self, weak engine] in
                guard let self, let engine, let input = self.prepared, input.engine === engine else { return }
                if self.isRecording {
                    // The engine has stopped delivering buffers. Finish with
                    // what we have rather than sit there silently until the
                    // key is released.
                    Log.info("[AUDIO] Audio configuration changed during recording — finishing early")
                    self.stopRecording()
                } else if self.idleRebuilds.allow(prepared: input.format, current: Self.currentFormats(of: engine)) {
                    Log.info("[AUDIO] Input format changed while idle — preparing again")
                    self.prepare()
                } else {
                    Log.info("[AUDIO] Audio configuration changed while idle — keeping the prepared engine (rebuilt \(self.idleRebuilds.inARow) of \(Self.idleRebuildLimit) times since the last recording)")
                }
            }
        }
    }

    private func removeConfigObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    /// A new default microphone (AirPods connecting, say) gets a fresh engine
    /// before the next key press. During a recording there is nothing to do:
    /// `prepare()` runs when it ends. One device change can also reach the
    /// configuration-change handler, so an engine already built under the
    /// current default is kept: one rebuild per change, whichever fires first.
    ///
    /// The listener stays registered for the life of the process. Swift hands
    /// Core Audio a new block on every call, so AudioObjectRemovePropertyListenerBlock
    /// never matches the one added (it still returns noErr). Capturing `self`
    /// weakly makes a leftover listener do nothing.
    private func observeDefaultInputDevice() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            guard let self, !self.isRecording else { return }
            if let input = self.prepared, input.defaultDevice == AudioDevices.defaultInputDevice() { return }
            Log.info("[AUDIO] Default input device changed — preparing again")
            self.prepare()
        }
        if status != noErr {
            Log.info("[AUDIO] Cannot watch the default input device (OSStatus \(status))")
        }
    }

    /// The chosen microphone came or went while idle (Task 24): a fresh
    /// engine, on it or on the system default, before the next key press.
    /// Following the system default, the default-device listener does that
    /// instead, and this does nothing. During a recording there is nothing to
    /// do: `prepare()` runs when it ends. Registered once (`AudioDevices`).
    private func observeDevices() {
        AudioDevices.observeDevices { [weak self] in
            guard let self, !self.isRecording else { return }
            let current = Self.microphone(forUID: self.inputDeviceUID, lookup: AudioDevices.deviceID(forUID:))
            guard Self.deviceChangeNeedsRebuild(forChosen: self.inputDeviceUID, isPrepared: self.prepared != nil,
                                    preparedDevice: self.prepared?.device, current: current) else { return }
            Log.info(current == nil ? "[AUDIO] The chosen microphone is gone — preparing the system default"
                                    : "[AUDIO] The chosen microphone is connected — preparing it")
            self.prepare()
        }
    }

    /// Whether a change in the connected devices calls for a new engine:
    /// only while a microphone is chosen (`uid`), and only when the device it
    /// now maps to (`current`, nil when it is not connected) is not the one
    /// the prepared engine records from (`preparedDevice`, nil for the system
    /// default), or nothing is prepared.
    static func deviceChangeNeedsRebuild(forChosen uid: String?, isPrepared: Bool, preparedDevice: AudioDeviceID?,
                             current: AudioDeviceID?) -> Bool {
        guard uid != nil else { return false }
        return !isPrepared || preparedDevice != current
    }

    /// The microphone to record from: the device with `uid`, as `lookup`
    /// (Core Audio) finds it while it is connected; nil, the system default,
    /// when none is chosen or the chosen one is not connected.
    static func microphone(forUID uid: String?, lookup: (String) -> AudioDeviceID?) -> AudioDeviceID? {
        uid.flatMap(lookup)
    }

    /// Sets the chosen microphone on the engine's input unit, if one is
    /// chosen and connected, and returns it; otherwise the engine keeps the
    /// system default, and this returns nil.
    private func selectMicrophone(on inputNode: AVAudioInputNode) -> AudioDeviceID? {
        Self.selectMicrophone(uid: inputDeviceUID, lookup: AudioDevices.deviceID(forUID:),
                              setDevice: { try inputNode.auAudioUnit.setDeviceID($0) })
    }

    /// The logic of `selectMicrophone(on:)`, with the lookup and the input
    /// unit passed in: `setDevice` is called only for a chosen microphone
    /// that is connected, and a failure of it also gives nil.
    static func selectMicrophone(uid: String?, lookup: (String) -> AudioDeviceID?,
                                 setDevice: (AudioDeviceID) throws -> Void) -> AudioDeviceID? {
        guard let uid else { return nil }
        guard let device = microphone(forUID: uid, lookup: lookup) else {
            Log.info("[AUDIO] Microphone \(uid) is not connected — using the system default")
            return nil
        }
        do {
            try setDevice(device)
            return device
        } catch {
            Log.info("[AUDIO] Cannot select microphone \(uid): \(error.localizedDescription) — using the system default")
            return nil
        }
    }
}

/// A recorder setup failure, worded for the menu bar.
private struct RecorderError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}
