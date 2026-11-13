import AVFoundation
import XCTest
@testable import VoiceDictationLib

final class AudioRecorderLogicTests: XCTestCase {
    private func format(_ sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    }

    // Review Focus 2: the input device changes between pre-warm and key-down.

    func testRebuildsWhenNothingIsPrepared() {
        XCTAssertTrue(AudioRecorder.needsRebuild(prepared: nil, current: format(48_000, channels: 1)))
    }

    func testKeepsPreparedEngineWhenFormatIsUnchanged() {
        XCTAssertFalse(AudioRecorder.needsRebuild(prepared: format(48_000, channels: 1), current: format(48_000, channels: 1)))
    }

    func testRebuildsWhenSampleRateChanges() {
        XCTAssertTrue(AudioRecorder.needsRebuild(prepared: format(48_000, channels: 1), current: format(24_000, channels: 1)))
    }

    func testRebuildsWhenChannelCountChanges() {
        XCTAssertTrue(AudioRecorder.needsRebuild(prepared: format(48_000, channels: 1), current: format(48_000, channels: 2)))
    }

    // A configuration change while idle: rebuild only when the format moved,
    // and not forever (each rebuild could cause the next).

    func testIdleChangeKeepsEngineWhenFormatIsUnchanged() {
        XCTAssertFalse(AudioRecorder.shouldRebuildWhenIdle(
            prepared: format(48_000, channels: 1), current: format(48_000, channels: 1), rebuildsInARow: 0))
    }

    func testIdleChangeRebuildsWhenFormatMoved() {
        XCTAssertTrue(AudioRecorder.shouldRebuildWhenIdle(
            prepared: format(48_000, channels: 1), current: format(24_000, channels: 1), rebuildsInARow: 0))
    }

    func testIdleChangeStopsRebuildingAtTheLimit() {
        XCTAssertFalse(AudioRecorder.shouldRebuildWhenIdle(
            prepared: format(48_000, channels: 1), current: format(24_000, channels: 1),
            rebuildsInARow: AudioRecorder.idleRebuildLimit))
    }

    func testIdleRebuildsResumeAfterARecording() {
        var rebuilds = AudioRecorder.IdleRebuilds()
        let prepared = format(48_000, channels: 1)
        let moved = [format(24_000, channels: 1)]
        for _ in 0..<AudioRecorder.idleRebuildLimit {
            XCTAssertTrue(rebuilds.allow(prepared: prepared, current: moved))
        }
        XCTAssertFalse(rebuilds.allow(prepared: prepared, current: moved))

        rebuilds.recordingEnded()

        XCTAssertTrue(rebuilds.allow(prepared: prepared, current: moved))
    }

    /// The tap path, without a microphone: 100 ms buffers at 48 kHz through
    /// one converter come out as one continuous 16 kHz stream.
    func testConvertsTapBuffersToContinuous16kMono() throws {
        let input = format(48_000, channels: 1)
        let converter = try XCTUnwrap(AVAudioConverter(from: input, to: AudioClip.audioFormat))
        var samples: [Float] = []
        for start in stride(from: 0, to: 5 * 48_000, by: 4_800) {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            for i in 0..<4_800 {
                channel[i] = Float(0.5 * sin(2 * Double.pi * 440 * Double(start + i) / 48_000))
            }
            samples += AudioRecorder.convert(buffer, with: converter)
        }

        // 5 s is 80 000 samples, less the resampler's one-off delay (15 ms
        // here). Losing samples on every buffer would add up past 30 ms.
        XCTAssertLessThanOrEqual(samples.count, 80_000)
        XCTAssertGreaterThan(samples.count, 80_000 - 480)
        XCTAssertEqual(AudioClip(samples: samples).peak, 0.5, accuracy: 0.02)
    }

    /// `inputDeviceUID` resolves through this; an unknown UID must fall back
    /// to the system default rather than fail. Reads device properties only.
    func testFindsMicrophoneByUID() throws {
        XCTAssertNil(AudioDevices.deviceID(forUID: "no-such-microphone"))

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let found = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard found == noErr, device != AudioDeviceID(kAudioObjectUnknown) else {
            throw XCTSkip("This Mac has no input device")
        }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        XCTAssertEqual(status, noErr)
        let defaultUID = try XCTUnwrap(uid?.takeRetainedValue() as String?)

        XCTAssertEqual(AudioDevices.deviceID(forUID: defaultUID), device)
        XCTAssertTrue(AudioDevices.inputDevices().contains { $0.uid == defaultUID },
                      "the default input is among the microphones Settings lists")
    }

    /// Settings' list: every device with an input, each with a UID that
    /// leads back to it and a name to show, sorted by name.
    func testListsTheMicrophonesWithNamesAndUIDs() {
        let devices = AudioDevices.inputDevices()
        for device in devices {
            XCTAssertFalse(device.uid.isEmpty)
            XCTAssertFalse(device.name.isEmpty, device.uid)
            XCTAssertNotNil(AudioDevices.deviceID(forUID: device.uid), device.uid)
        }
        XCTAssertEqual(devices.map(\.name), devices.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertEqual(Set(devices.map(\.uid)).count, devices.count, "one row per device")
    }

    // Task 24: a chosen microphone that comes or goes while idle.

    /// Following the system default, the device list changes nothing: the
    /// default-device listener rebuilds when the default moves.
    func testNoMicrophoneChosenIgnoresTheDeviceList() {
        XCTAssertFalse(AudioRecorder.needsRebuild(forChosen: nil, isPrepared: true, preparedDevice: nil, current: nil))
        XCTAssertFalse(AudioRecorder.needsRebuild(forChosen: nil, isPrepared: false, preparedDevice: nil, current: nil))
    }

    /// The chosen microphone unplugged: the engine built on it records
    /// nothing, so a new one on the system default. Plugged back in: a new
    /// one on it. Unchanged: the prepared engine is kept.
    func testAChosenMicrophoneThatComesOrGoesRebuilds() {
        let uid = "AppleUSBAudioEngine:Blue:Yeti:1"
        XCTAssertTrue(AudioRecorder.needsRebuild(forChosen: uid, isPrepared: true, preparedDevice: 81, current: nil), "gone")
        XCTAssertTrue(AudioRecorder.needsRebuild(forChosen: uid, isPrepared: true, preparedDevice: nil, current: 81), "back")
        XCTAssertFalse(AudioRecorder.needsRebuild(forChosen: uid, isPrepared: true, preparedDevice: 81, current: 81))
        XCTAssertFalse(AudioRecorder.needsRebuild(forChosen: uid, isPrepared: true, preparedDevice: nil, current: nil),
                       "still gone: the engine on the system default stays")
        XCTAssertTrue(AudioRecorder.needsRebuild(forChosen: uid, isPrepared: false, preparedDevice: nil, current: 81),
                      "nothing prepared: try again")
    }

    /// The device the recorder sets on the engine's input unit: the chosen
    /// one while connected, otherwise none, which leaves the system default.
    func testTheChosenMicrophoneOrTheSystemDefault() {
        let connected: (String) -> AudioDeviceID? = { $0 == "BuiltInMicrophoneDevice" ? 73 : nil }
        XCTAssertEqual(AudioRecorder.microphone(forUID: "BuiltInMicrophoneDevice", lookup: connected), 73)
        XCTAssertNil(AudioRecorder.microphone(forUID: "AppleUSBAudioEngine:Blue:Yeti:1", lookup: connected))
        XCTAssertNil(AudioRecorder.microphone(forUID: nil, lookup: connected))
    }

    /// The start and stop sounds are the system's Tink and Pop, through
    /// System Sound Services. Loading one plays nothing; a sound that is not
    /// there is none, and the recorder then plays nothing.
    func testTheStartAndStopSoundsLoad() {
        XCTAssertNotNil(SystemSound(named: "Tink"))
        XCTAssertNotNil(SystemSound(named: "Pop"))
        XCTAssertNil(SystemSound(named: "NoSuchSound"))
    }

    func testVerdictTooShort() {
        XCTAssertEqual(AudioRecorder.verdict(duration: 0.49, peak: 0.5), .tooShort)
    }

    func testVerdictSilent() {
        XCTAssertEqual(AudioRecorder.verdict(duration: 2, peak: 0.009), .silent)
    }

    func testVerdictKeep() {
        XCTAssertEqual(AudioRecorder.verdict(duration: 0.5, peak: 0.01), .keep)
    }
}
