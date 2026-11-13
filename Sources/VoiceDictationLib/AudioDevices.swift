import CoreAudio
import Foundation

/// A microphone the Mac has, as Settings lists it: Core Audio's UID, which
/// stays the same across launches and restarts (AudioHardwareBase.h,
/// `kAudioDevicePropertyDeviceUID`), and the name to show.
public struct AudioInputDevice: Equatable, Hashable, Identifiable, Sendable {
    public let uid: String
    public let name: String

    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// The Mac's audio devices, read from Core Audio's system object. Property
/// reads only (AudioHardware.h): no audio runs and no permission is asked.
public enum AudioDevices {
    /// Every device with an input stream, by name: the microphones Settings
    /// offers. Hidden devices are not in Core Audio's device list
    /// (`kAudioDevicePropertyIsHidden`), so they are not here either.
    public static func inputDevices() -> [AudioInputDevice] {
        allDevices().compactMap { device -> AudioInputDevice? in
            guard hasInput(device), let uid = string(kAudioDevicePropertyDeviceUID, of: device) else { return nil }
            return AudioInputDevice(uid: uid, name: string(kAudioObjectPropertyName, of: device) ?? uid)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

    /// The Core Audio device with this UID, or nil when none is connected:
    /// for an unknown UID, `kAudioHardwarePropertyTranslateUIDToDevice`
    /// gives `kAudioObjectUnknown` rather than an error (AudioHardware.h).
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

    /// Calls `onChange` on the main queue each time a device comes or goes
    /// (`kAudioHardwarePropertyDevices`). The listener stays for the life of
    /// the process: Swift hands Core Audio a new block on every call, so
    /// `AudioObjectRemovePropertyListenerBlock` would never match it (Task 4).
    /// So each owner calls this once, and `onChange` holds its owner weakly.
    public static func observeDevices(_ onChange: @escaping @MainActor () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            MainActor.assumeIsolated { onChange() }
        }
        if status != noErr {
            Log.info("[AUDIO] Cannot watch the audio devices (OSStatus \(status))")
        }
    }

    // MARK: - Reading Core Audio

    /// Every device Core Audio lists now.
    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown),
                                      count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = devices.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { return [] }
        // A device can go between the two calls; the size says how many came back.
        return Array(devices.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    /// Whether the device has an input stream (`kAudioDevicePropertyStreams`
    /// in the input scope): a microphone, or another device that records.
    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    /// A device's CFString property. Core Audio hands it over retained ("The
    /// caller is responsible for releasing the returned CFObject").
    private static func string(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
