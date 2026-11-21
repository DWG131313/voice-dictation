import AVFoundation
import Observation

/// Plays one kept recording at a time, for the detail's Play audio: an
/// `AVAudioPlayer` on the file in the audio archive. Starting another stops
/// the first. Use from the main thread, where AVFoundation calls its delegate.
@MainActor @Observable
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    /// The recording playing now; nil while nothing plays. Set only here,
    /// and by tests standing in for playback (no test plays audio).
    var playing: URL?
    @ObservationIgnored private var player: AVAudioPlayer?

    /// Plays the recording at `url` from its start, stopping any other.
    /// Throws when the file cannot be read or played; nothing plays then.
    func play(_ url: URL) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        guard player.play() else { throw PlaybackError.couldNotStart }
        self.player = player
        playing = url
    }

    /// Stops the recording playing, if any.
    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }
        self.player = nil
        playing = nil
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === self.player else { return }
        stop()
    }

    enum PlaybackError: Error {
        /// `AVAudioPlayer.play()` said no.
        case couldNotStart
    }
}
