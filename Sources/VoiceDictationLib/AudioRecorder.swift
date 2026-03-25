import AVFoundation
import Cocoa

public protocol AudioRecorderDelegate: AnyObject {
    func recordingDidStart()
    func recordingDidFinish(fileURL: URL, duration: TimeInterval)
    func recordingDidFail(error: String)
    func recordingDiscarded()
}

public class AudioRecorder {
    public weak var delegate: AudioRecorderDelegate?

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var recordingURL: URL?
    private var recordingStartTime: Date?
    private let minimumDuration: TimeInterval = 0.5

    private let tickOnSound = NSSound(named: .init("Tink"))
    private let tickOffSound = NSSound(named: .init("Pop"))

    public init() {}

    public func startRecording() {
        let inputNode = engine.inputNode

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
            delegate?.recordingDidFail(error: "Failed to create audio file: \(error.localizedDescription)")
            return
        }

        // Record at hardware's native format, convert each buffer before writing
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        let convertFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        converter = AVAudioConverter(from: hardwareFormat, to: convertFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self = self,
                  let audioFile = self.audioFile,
                  let converter = self.converter else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * 16000.0 / hardwareFormat.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: convertFormat, frameCapacity: frameCount) else { return }

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

            if error == nil {
                do {
                    try audioFile.write(from: convertedBuffer)
                } catch {
                    print("Error writing audio buffer: \(error)")
                }
            }
        }

        do {
            try engine.start()
            recordingStartTime = Date()
            tickOnSound?.play()
            delegate?.recordingDidStart()
        } catch {
            cleanup()
            delegate?.recordingDidFail(error: "Microphone in use by another app")
        }
    }

    public func stopRecording() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil

        tickOffSound?.play()

        guard let startTime = recordingStartTime,
              let fileURL = recordingURL else {
            delegate?.recordingDiscarded()
            return
        }

        let duration = Date().timeIntervalSince(startTime)

        if duration < minimumDuration {
            // Too short — accidental tap
            cleanupFile(at: fileURL)
            delegate?.recordingDiscarded()
            return
        }

        delegate?.recordingDidFinish(fileURL: fileURL, duration: duration)
        recordingStartTime = nil
    }

    public func cancelRecording() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil

        if let fileURL = recordingURL {
            cleanupFile(at: fileURL)
        }

        recordingStartTime = nil
        delegate?.recordingDiscarded()
    }

    public func cleanupFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func cleanup() {
        audioFile = nil
        if let url = recordingURL {
            cleanupFile(at: url)
        }
        recordingURL = nil
        recordingStartTime = nil
    }
}
