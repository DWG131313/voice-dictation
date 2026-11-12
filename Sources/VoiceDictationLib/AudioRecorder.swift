import AVFoundation
import Cocoa
import ObjCHelpers

public protocol AudioRecorderDelegate: AnyObject {
    func recordingDidStart()
    func recordingDidFinish(fileURL: URL, duration: TimeInterval)
    func recordingDidFail(error: String)
    func recordingDiscarded()
}

public class AudioRecorder {
    public weak var delegate: AudioRecorderDelegate?

    // A fresh engine per recording. Reusing one across input-device changes
    // (AirPods connecting, a USB mic unplugged) leaves it with a stale input
    // format and it silently records nothing.
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var recordingURL: URL?
    private var recordingStartTime: Date?
    private var maxDurationTimer: Timer?
    private var configChangeObserver: NSObjectProtocol?

    // Loudest sample seen this recording (0...1), updated on the audio thread.
    private let peakLock = NSLock()
    private var peakAmplitude: Float = 0
    /// Recordings whose peak never rises above this are treated as silence and
    /// discarded without running whisper. Whisper hallucinates words like
    /// "you" or "Thank you." on silent input, and a muted or absent mic would
    /// otherwise paste those. -40 dBFS is far below any audible speech.
    public var silenceThreshold: Float = 0.01

    private let minimumDuration: TimeInterval = 0.5
    /// Safety net: if the key-up event is ever lost, stop on our own rather
    /// than recording forever.
    public var maximumDuration: TimeInterval = 300

    public private(set) var isRecording = false

    private let tickOnSound = NSSound(named: .init("Tink"))
    private let tickOffSound = NSSound(named: .init("Pop"))

    public init() {}

    deinit {
        removeConfigObserver()
        maxDurationTimer?.invalidate()
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

        let engine = AVAudioEngine()
        self.engine = engine
        let inputNode = engine.inputNode

        // Validate audio format (0 channels means no mic access or no device)
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        Log.info("[AUDIO] Input format: channels=\(hardwareFormat.channelCount) sampleRate=\(hardwareFormat.sampleRate)")
        guard hardwareFormat.channelCount > 0, hardwareFormat.sampleRate > 0 else {
            self.engine = nil
            delegate?.recordingDidFail(error: "No microphone available. Check System Settings > Privacy & Security > Microphone.")
            return
        }

        // Create temp file
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "voice-dictation-\(Int(Date().timeIntervalSince1970)).wav"
        let fileURL = tempDir.appendingPathComponent(fileName)
        recordingURL = fileURL

        // Target format: 16kHz mono PCM 16-bit (what whisper.cpp expects)
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!

        do {
            audioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: outputFormat.settings
            )
        } catch {
            cleanup()
            delegate?.recordingDidFail(error: "Failed to create audio file: \(error.localizedDescription)")
            return
        }

        // Record at hardware's native format, convert each buffer before writing
        let convertFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: hardwareFormat, to: convertFormat) else {
            cleanup()
            delegate?.recordingDidFail(error: "Unsupported microphone format (\(Int(hardwareFormat.sampleRate)) Hz, \(hardwareFormat.channelCount) ch)")
            return
        }
        self.converter = converter

        // Wrap in ObjC exception catcher — installTap throws NSException (not Swift Error)
        // when mic permission is denied or format is invalid
        do {
            try ObjCExceptionCatcher.`try`({
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
                    guard let self = self,
                          let audioFile = self.audioFile,
                          let converter = self.converter else { return }

                    let frameCount = AVAudioFrameCount(
                        (Double(buffer.frameLength) * 16000.0 / hardwareFormat.sampleRate).rounded(.up)
                    )
                    guard frameCount > 0,
                          let convertedBuffer = AVAudioPCMBuffer(pcmFormat: convertFormat, frameCapacity: frameCount) else { return }

                    var error: NSError?
                    var hasData = true  // Track whether input buffer has been consumed
                    converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                        if hasData {
                            hasData = false
                            outStatus.pointee = .haveData
                            return buffer
                        } else {
                            outStatus.pointee = .noDataNow
                            return nil
                        }
                    }

                    if error == nil, convertedBuffer.frameLength > 0 {
                        self.trackPeak(in: convertedBuffer)
                        do {
                            try audioFile.write(from: convertedBuffer)
                        } catch {
                            Log.info("[AUDIO] Error writing audio buffer: \(error)")
                        }
                    }
                }
            })
        } catch {
            cleanup()
            delegate?.recordingDidFail(error: "Cannot access microphone: \(error.localizedDescription)")
            return
        }

        do {
            try engine.start()
        } catch {
            cleanup()
            delegate?.recordingDidFail(error: "Microphone in use by another app")
            return
        }

        isRecording = true
        peakLock.lock(); peakAmplitude = 0; peakLock.unlock()
        recordingStartTime = Date()
        installConfigObserver(for: engine)
        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maximumDuration, repeats: false) { [weak self] _ in
            Log.info("[AUDIO] Maximum recording duration reached — stopping automatically")
            self?.stopRecording()
        }
        tickOnSound?.play()
        delegate?.recordingDidStart()
    }

    public func stopRecording() {
        guard isRecording else { return }
        tearDownEngine()

        tickOffSound?.play()

        guard let startTime = recordingStartTime,
              let fileURL = recordingURL else {
            cleanup()
            delegate?.recordingDiscarded()
            return
        }

        let duration = Date().timeIntervalSince(startTime)
        recordingStartTime = nil
        recordingURL = nil

        if duration < minimumDuration {
            // Too short — accidental tap
            cleanupFile(at: fileURL)
            delegate?.recordingDiscarded()
            return
        }

        peakLock.lock(); let peak = peakAmplitude; peakLock.unlock()
        if peak < silenceThreshold {
            Log.info("[AUDIO] Recording of \(String(format: "%.1f", duration))s was silent (peak \(peak)) — discarding")
            cleanupFile(at: fileURL)
            delegate?.recordingDiscarded()
            return
        }

        Log.info("[AUDIO] Recording finished: \(String(format: "%.1f", duration))s, peak \(String(format: "%.2f", peak))")
        delegate?.recordingDidFinish(fileURL: fileURL, duration: duration)
    }

    public func cancelRecording() {
        guard isRecording else { return }
        tearDownEngine()
        cleanup()
        delegate?.recordingDiscarded()
    }

    public func cleanupFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Private

    private func trackPeak(in buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            let v = abs(channel[i])
            if v > peak { peak = v }
        }
        peakLock.lock()
        if peak > peakAmplitude { peakAmplitude = peak }
        peakLock.unlock()
    }

    /// If the default input device changes mid-recording the engine stops
    /// delivering buffers. Finish with what we have rather than sit there
    /// silently until the key is released.
    private func installConfigObserver(for engine: AVAudioEngine) {
        removeConfigObserver()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            Log.info("[AUDIO] Audio configuration changed during recording — finishing early")
            self.stopRecording()
        }
    }

    private func removeConfigObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    private func tearDownEngine() {
        isRecording = false
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
        removeConfigObserver()
        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
        audioFile = nil  // Releasing the file finalizes the WAV header
    }

    private func cleanup() {
        tearDownEngine()
        if let url = recordingURL {
            cleanupFile(at: url)
        }
        recordingURL = nil
        recordingStartTime = nil
    }
}
