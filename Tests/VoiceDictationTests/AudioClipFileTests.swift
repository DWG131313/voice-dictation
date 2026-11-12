import AVFoundation
import XCTest
@testable import VoiceDictationLib

final class AudioClipFileTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-clip-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A 440 Hz sine at half scale.
    private func sine(seconds: Double, sampleRate: Double = AudioClip.sampleRate) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / sampleRate)) }
    }

    func testWAVRoundTrip() throws {
        let clip = AudioClip(samples: sine(seconds: 1))
        let url = directory.appendingPathComponent("clip.wav")

        try clip.writeWAV(to: url)
        let loaded = try AudioClip(contentsOf: url)

        XCTAssertEqual(Double(loaded.samples.count), 16_000, accuracy: 1)
        XCTAssertEqual(loaded.peak, clip.peak, accuracy: 0.01)
    }

    func testALACRoundTripIsLossless() throws {
        let clip = AudioClip(samples: sine(seconds: 1))
        let url = directory.appendingPathComponent("clip.m4a")

        try clip.writeALAC(to: url)
        let loaded = try AudioClip(contentsOf: url)

        XCTAssertEqual(loaded.samples.count, clip.samples.count)
        let largestDifference = zip(clip.samples, loaded.samples).map { abs($0 - $1) }.max() ?? .infinity
        XCTAssertLessThan(largestDifference, 1.0 / 32_768)
    }

    func testReads44kStereoAsMono16k() throws {
        let url = directory.appendingPathComponent("stereo.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let tone = sine(seconds: 1, sampleRate: 44_100)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(tone.count)))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            let data = try XCTUnwrap(buffer.floatChannelData?[channel])
            for (i, sample) in tone.enumerated() { data[i] = sample }
        }
        try file.write(from: buffer)
        file.close()

        let clip = try AudioClip(contentsOf: url)

        XCTAssertEqual(clip.duration, 1.0, accuracy: 0.01)
        XCTAssertGreaterThan(clip.peak, 0.25, "the tone should survive the mix to mono")
    }
}
