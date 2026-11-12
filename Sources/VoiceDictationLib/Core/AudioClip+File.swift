import AVFoundation

/// Why a clip could not be read from or written to a file.
public enum AudioClipFileError: LocalizedError {
    /// AVAudioConverter cannot turn this format into 16 kHz mono.
    case unsupportedFormat(String)
    /// Core Audio failed without giving an error of its own.
    case conversionFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format): "Cannot convert \(format) audio to 16 kHz mono"
        case .conversionFailed: "Audio conversion failed"
        }
    }
}

extension AudioClip {
    /// The clip's samples as Core Audio sees them: 16 kHz, mono, 32-bit float.
    static let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
    )!

    /// Reads any audio file AVAudioFile can open and converts it to 16 kHz
    /// mono. Channels are mixed down rather than dropped, so a stereo file
    /// with speech on one side still has it.
    public init(contentsOf url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        self.init(samples: try Self.samples(from: file))
    }

    /// 16-bit PCM WAV, the format whisper-cli reads.
    public func writeWAV(to url: URL) throws {
        try write(to: url, settings: [
            AVAudioFileTypeKey: kAudioFileWAVEType,
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
    }

    /// Apple Lossless in an .m4a container, from 16-bit samples: smaller than
    /// the WAV and loses nothing beyond 16-bit rounding.
    public func writeALAC(to url: URL) throws {
        try write(to: url, settings: [
            AVAudioFileTypeKey: kAudioFileM4AType,
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitDepthHintKey: 16,
        ])
    }

    /// Writes the samples with `settings` as the file format. A failed write
    /// removes the partial file.
    private func write(to url: URL, settings: [String: Any]) throws {
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        do {
            if !samples.isEmpty {
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)
                ), let channel = buffer.floatChannelData?[0] else {
                    throw AudioClipFileError.conversionFailed
                }
                buffer.frameLength = buffer.frameCapacity
                samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
                try file.write(from: buffer)
            }
            file.close()
        } catch {
            file.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Streams the whole file through a converter, a chunk at a time.
    private static func samples(from file: AVAudioFile) throws -> [Float] {
        let input = file.processingFormat
        guard let converter = AVAudioConverter(from: input, to: audioFormat) else {
            throw AudioClipFileError.unsupportedFormat("\(Int(input.sampleRate)) Hz, \(input.channelCount) ch")
        }
        converter.downmix = true

        let chunk: AVAudioFrameCount = 16_384
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: chunk),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: chunk) else {
            throw AudioClipFileError.conversionFailed
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int((Double(file.length) * sampleRate / input.sampleRate).rounded(.up)))
        var readError: Error?
        while true {
            var conversionError: NSError?
            // The converter calls this again only once it has used the last
            // chunk, so refilling the one input buffer is safe.
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                guard file.framePosition < file.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inputBuffer, frameCount: chunk)
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard inputBuffer.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if let readError { throw readError }
            if status == .error { throw conversionError ?? AudioClipFileError.conversionFailed }
            if outputBuffer.frameLength > 0, let channel = outputBuffer.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
            }
            // `.haveData` means the buffer filled up and more may follow. The
            // input never runs dry mid-file, so anything else is the end.
            guard status == .haveData, outputBuffer.frameLength > 0 else { break }
        }
        return samples
    }
}
