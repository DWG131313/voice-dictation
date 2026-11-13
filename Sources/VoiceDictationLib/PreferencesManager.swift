import Foundation
import Observation

/// Where `PreferencesManager` keeps its values: `UserDefaults` in the app.
/// Tests pass one kept in memory, since every `UserDefaults` suite leaves a
/// file in `~/Library/Preferences`, even after its domain is removed.
protocol PreferenceStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func string(forKey defaultName: String) -> String?
    func bool(forKey defaultName: String) -> Bool
    func integer(forKey defaultName: String) -> Int
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: PreferenceStore {}

/// The app's settings, kept in its defaults domain and read from there each
/// time, so nothing is cached. Observable (Task 24): the values live in the
/// store rather than in stored properties, so each one reports its own reads
/// and writes (`access` and `withMutation`, which `@Observable` provides),
/// and a view showing a setting is drawn again when anything changes it.
@Observable
public class PreferencesManager {
    public static let shared = PreferencesManager()

    private let defaults: PreferenceStore

    // MARK: - Keys
    private enum Keys {
        static let selectedModel = "selectedModel"
        static let selectedModelID = "selectedModelID"
        static let launchAtLogin = "launchAtLogin"
        static let keptRecordings = "keptRecordings"
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let onboardingTriedIt = "onboardingTriedIt"
        static let cleanupEnabled = "cleanupEnabled"
        static let hotkey = "hotkey"
        static let doubleTapEnabled = "doubleTapEnabled"
        static let pasteLastHotkeyEnabled = "pasteLastHotkeyEnabled"
        static let inputDeviceUID = "inputDeviceUID"
        static let soundsEnabled = "soundsEnabled"
    }

    // MARK: - Available Models
    public struct WhisperModel: Codable, Equatable {
        public let id: String        // e.g. "base.en"
        public let fileName: String  // e.g. "ggml-base.en.bin"
        public let displayName: String
        public let sizeDescription: String
        public let downloadURL: URL

        public static let available: [WhisperModel] = [
            WhisperModel(
                id: "tiny.en",
                fileName: "ggml-tiny.en.bin",
                displayName: "Tiny (English)",
                sizeDescription: "~75 MB — fastest, lower accuracy",
                downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin")!
            ),
            WhisperModel(
                id: "base.en",
                fileName: "ggml-base.en.bin",
                displayName: "Base (English)",
                sizeDescription: "~150 MB — good balance",
                downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!
            ),
            WhisperModel(
                id: "small.en",
                fileName: "ggml-small.en.bin",
                displayName: "Small (English)",
                sizeDescription: "~500 MB — best accuracy, slower",
                downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin")!
            ),
        ]
    }

    // MARK: - Properties
    public var selectedModelId: String {
        get {
            access(keyPath: \.selectedModelId)
            return defaults.string(forKey: Keys.selectedModel) ?? "base.en"
        }
        set { withMutation(keyPath: \.selectedModelId) { defaults.set(newValue, forKey: Keys.selectedModel) } }
    }

    public var selectedModel: WhisperModel {
        WhisperModel.available.first { $0.id == selectedModelId } ?? WhisperModel.available[1]
    }

    /// The model dictation uses, saved as its `storageKey`. Until one is
    /// saved, a whisper-cli model chosen in the old app carries over.
    public var selectedModelID: ModelID {
        get {
            access(keyPath: \.selectedModelID)
            return Self.selectedModelID(saved: defaults.string(forKey: Keys.selectedModelID),
                                        legacy: defaults.string(forKey: Keys.selectedModel))
        }
        set { withMutation(keyPath: \.selectedModelID) { defaults.set(newValue.storageKey, forKey: Keys.selectedModelID) } }
    }

    /// A saved choice wins. Otherwise the old app's `selectedModel` becomes
    /// that whisper-cli model, so the app keeps working on first run even if
    /// Apple's language files are missing. Anything else is Apple Speech.
    static func selectedModelID(saved: String?, legacy: String?) -> ModelID {
        if let saved, let id = ModelID(storageKey: saved) { return id }
        if let legacy, WhisperModel.available.contains(where: { $0.id == legacy }) {
            return ModelID(engine: .whisperCLI, name: legacy)
        }
        return .appleSpeech
    }

    /// Whether the user wants the app to open at login. Defaults to off; the
    /// user opts in from Settings. Only takes effect for an installed `.app`
    /// bundle (see `LoginItemManager`).
    public var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return defaults.bool(forKey: Keys.launchAtLogin)
        }
        set { withMutation(keyPath: \.launchAtLogin) { defaults.set(newValue, forKey: Keys.launchAtLogin) } }
    }

    /// How many recent recordings the app keeps for replay and
    /// re-transcription. 0 keeps none for new dictations; failed and pinned
    /// ones are always kept and not counted (`TranscriptStore.prune`).
    public static let defaultKeptRecordings = 50

    public var keptRecordings: Int {
        get {
            access(keyPath: \.keptRecordings)
            guard defaults.object(forKey: Keys.keptRecordings) != nil else { return Self.defaultKeptRecordings }
            return max(0, defaults.integer(forKey: Keys.keptRecordings))
        }
        set { withMutation(keyPath: \.keptRecordings) { defaults.set(max(0, newValue), forKey: Keys.keptRecordings) } }
    }

    /// True once the app has been started before; the Welcome window shows
    /// itself on the first launch whatever else is set up.
    public var hasLaunchedBefore: Bool {
        get {
            access(keyPath: \.hasLaunchedBefore)
            return defaults.bool(forKey: Keys.hasLaunchedBefore)
        }
        set { withMutation(keyPath: \.hasLaunchedBefore) { defaults.set(newValue, forKey: Keys.hasLaunchedBefore) } }
    }

    /// True once a dictation has pasted: the Welcome window's last step.
    public var onboardingTriedIt: Bool {
        get {
            access(keyPath: \.onboardingTriedIt)
            return defaults.bool(forKey: Keys.onboardingTriedIt)
        }
        set { withMutation(keyPath: \.onboardingTriedIt) { defaults.set(newValue, forKey: Keys.onboardingTriedIt) } }
    }

    /// "Clean up transcripts": dictations are cleaned up on the Mac before
    /// they paste (Task 21). On until switched off; while Apple Intelligence
    /// is unavailable the cleaner is skipped whatever this says.
    public var cleanupEnabled: Bool {
        get {
            access(keyPath: \.cleanupEnabled)
            guard defaults.object(forKey: Keys.cleanupEnabled) != nil else { return true }
            return defaults.bool(forKey: Keys.cleanupEnabled)
        }
        set { withMutation(keyPath: \.cleanupEnabled) { defaults.set(newValue, forKey: Keys.cleanupEnabled) } }
    }

    /// The key held to dictate (Task 23), saved by its raw value. Globe
    /// until another is chosen; a saved value this version does not know
    /// reads as Globe. The event tap reads it when it starts.
    public var hotkey: HotkeyChoice {
        get {
            access(keyPath: \.hotkey)
            return defaults.string(forKey: Keys.hotkey).flatMap(HotkeyChoice.init(rawValue:)) ?? .globe
        }
        set { withMutation(keyPath: \.hotkey) { defaults.set(newValue.rawValue, forKey: Keys.hotkey) } }
    }

    /// "Double-tap to dictate": a quick double tap of the hotkey records
    /// until another double tap stops it (Task 23). Off until switched on;
    /// read at each press. Saved as `doubleTapEnabled` since Task 24, with
    /// no migration: the setting was in no window before.
    public var doubleTapEnabled: Bool {
        get {
            access(keyPath: \.doubleTapEnabled)
            return defaults.bool(forKey: Keys.doubleTapEnabled)
        }
        set { withMutation(keyPath: \.doubleTapEnabled) { defaults.set(newValue, forKey: Keys.doubleTapEnabled) } }
    }

    /// Control-Option-V pastes the last transcript, as the menu's Paste Last
    /// Transcript does (Task 23). Off until switched on; read at each key.
    public var pasteLastHotkeyEnabled: Bool {
        get {
            access(keyPath: \.pasteLastHotkeyEnabled)
            return defaults.bool(forKey: Keys.pasteLastHotkeyEnabled)
        }
        set {
            withMutation(keyPath: \.pasteLastHotkeyEnabled) {
                defaults.set(newValue, forKey: Keys.pasteLastHotkeyEnabled)
            }
        }
    }

    /// The Core Audio UID of the microphone to record from (Task 24); nil,
    /// the default, follows the system's default input. A UID whose device
    /// is not connected is kept, and the recorder uses the default until it
    /// comes back. Setting nil removes the saved UID.
    public var inputDeviceUID: String? {
        get {
            access(keyPath: \.inputDeviceUID)
            return defaults.string(forKey: Keys.inputDeviceUID)
        }
        set { withMutation(keyPath: \.inputDeviceUID) { defaults.set(newValue, forKey: Keys.inputDeviceUID) } }
    }

    /// "Start and stop sounds": the recorder plays the system's Tink when a
    /// recording starts and Pop when it ends (Task 24). On until switched off.
    public var soundsEnabled: Bool {
        get {
            access(keyPath: \.soundsEnabled)
            guard defaults.object(forKey: Keys.soundsEnabled) != nil else { return true }
            return defaults.bool(forKey: Keys.soundsEnabled)
        }
        set { withMutation(keyPath: \.soundsEnabled) { defaults.set(newValue, forKey: Keys.soundsEnabled) } }
    }

    /// The app uses `shared`, on the standard defaults.
    init(defaults: PreferenceStore = UserDefaults.standard) {
        self.defaults = defaults
    }
}
