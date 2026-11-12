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
    /// The peak (0...1) of each converted buffer while recording, on the main queue.
    public var onLevel: ((Float) -> Void)?
    /// The Core Audio UID of the microphone to record from; nil follows the
    /// system default, as does a UID that matches no connected device.
    /// Setting it prepares again (after the current recording, if one is running).
    public var inputDeviceUID: String? {
        didSet { if inputDeviceUID != oldValue { prepare() } }
    }

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

    private let tickOnSound = NSSound(named: .init("Tink"))
    private let tickOffSound = NSSound(named: .init("Pop"))

    public init() {
        observeDefaultInputDevice()
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
                input.engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: input.format) { [weak self] buffer, _ in
                    self?.receive(buffer, converter: converter, recordingID: id)
                }
            })
            tapInstalled = true
        } catch {
            discardEngine()
            delegate?.recordingDidFail(error: "Cannot access microphone: \(error.localizedDescription)")
            return
        }

        do {
            try input.engine.start()
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
        tickOnSound?.play()
        delegate?.recordingDidStart()
    }

    /// Ends the recording and calls the delegate before returning.
    public func stopRecording() {
        guard isRecording else { return }
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let captured = endCapture()
        tickOffSound?.play()

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
        let defaultDevice = Self.defaultInputDevice()
        let engine = AVAudioEngine()
        if let uid = inputDeviceUID {
            select(microphone: uid, on: engine.inputNode)
        }

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

        let input = PreparedInput(engine: engine, converter: converter, format: format, defaultDevice: defaultDevice)
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

    /// Runs on the tap's thread for every buffer.
    private func receive(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, recordingID id: Int) {
        let arrived = Date()
        let samples = Self.convert(buffer, with: converter)
        let level = samples.reduce(0) { max($0, abs($1)) }
        let isFirst: Bool? = captureLock.withLock {
            guard capture.isOpen, capture.recordingID == id else { return nil }
            capture.samples.append(contentsOf: samples)
            capture.peak = max(capture.peak, level)
            guard capture.firstAudio == nil else { return false }
            capture.firstAudio = arrived
            return true
        }
        guard let isFirst else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording, self.recordingID == id else { return }
            if isFirst { self.deliverFirstAudio() }
            self.onLevel?(level)
        }
    }

    /// Converts one tap buffer to 16 kHz mono. The converter keeps its
    /// resampling state between buffers, so they join seamlessly.
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float] {
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * AudioClip.sampleRate / buffer.format.sampleRate).rounded(.up)
        )
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return [] }

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
        guard status != .error, error == nil, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
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
            if let input = self.prepared, input.defaultDevice == Self.defaultInputDevice() { return }
            Log.info("[AUDIO] Default input device changed — preparing again")
            self.prepare()
        }
        if status != noErr {
            Log.info("[AUDIO] Cannot watch the default input device (OSStatus \(status))")
        }
    }

    /// The system's default input device, or nil when there is none.
    static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return device
    }

    /// Points the engine's input at the microphone with this UID, if it is
    /// connected; otherwise the engine keeps the system default.
    private func select(microphone uid: String, on inputNode: AVAudioInputNode) {
        guard let device = Self.deviceID(forUID: uid) else {
            Log.info("[AUDIO] Microphone \(uid) is not connected — using the system default")
            return
        }
        do {
            try inputNode.auAudioUnit.setDeviceID(device)
        } catch {
            Log.info("[AUDIO] Cannot select microphone \(uid): \(error.localizedDescription) — using the system default")
        }
    }

    /// The Core Audio device with this UID, or nil when none is connected.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qualifierPointer, &size, &device
            )
        }
        guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return device
    }
}

/// A recorder setup failure, worded for the menu bar.
private struct RecorderError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}
