import AudioToolbox
import Foundation

/// A short sound from `/System/Library/Sounds`, played by System Sound
/// Services (AudioServices.h): `play()` hands it to the system sound server
/// and returns at once. It is heard whatever "Play user interface sound
/// effects" says (`kAudioServicesPropertyIsUISound` 0), as the `NSSound` it
/// replaces was; Settings has its own switch. Nil when the file is missing.
final class SystemSound {
    private let id: SystemSoundID

    init?(named name: String) {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        var id: SystemSoundID = 0
        // A missing file is an error here (-1500 on this Mac), not a silent sound.
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else {
            Log.info("[AUDIO] The \(name) sound is not available")
            return nil
        }
        var isUISound: UInt32 = 0
        let status = AudioServicesSetProperty(kAudioServicesPropertyIsUISound, UInt32(MemoryLayout<SystemSoundID>.size),
                                              &id, UInt32(MemoryLayout<UInt32>.size), &isUISound)
        if status != noErr {
            // The sound still plays, but "Play user interface sound effects"
            // may mute it.
            Log.info("[AUDIO] Cannot make the \(name) sound independent of the UI sound setting (OSStatus \(status))")
        }
        self.id = id
    }

    deinit {
        AudioServicesDisposeSystemSoundID(id)
    }

    func play() {
        AudioServicesPlaySystemSoundWithCompletion(id, nil)
    }
}
