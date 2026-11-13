import Foundation

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

public class PreferencesManager {
    public static let shared = PreferencesManager()

    private let defaults: PreferenceStore

    // MARK: - Keys
    private enum Keys {
        static let selectedModel = "selectedModel"
        static let selectedModelID = "selectedModelID"
        static let historyEnabled = "historyEnabled"
        static let maxHistoryItems = "maxHistoryItems"
        static let launchAtLogin = "launchAtLogin"
        static let keepComparisonRecordings = "keepComparisonRecordings"
        static let keptRecordings = "keptRecordings"
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let onboardingTriedIt = "onboardingTriedIt"
        static let cleanupEnabled = "cleanupEnabled"
        static let hotkey = "hotkey"
        static let handsFreeEnabled = "handsFreeEnabled"
        static let pasteLastHotkeyEnabled = "pasteLastHotkeyEnabled"
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
        get { defaults.string(forKey: Keys.selectedModel) ?? "base.en" }
        set { defaults.set(newValue, forKey: Keys.selectedModel) }
    }

    public var selectedModel: WhisperModel {
        WhisperModel.available.first { $0.id == selectedModelId } ?? WhisperModel.available[1]
    }

    /// The model dictation uses, saved as its `storageKey`. Until one is
    /// saved, a whisper-cli model chosen in the old app carries over.
    public var selectedModelID: ModelID {
        get {
            Self.selectedModelID(saved: defaults.string(forKey: Keys.selectedModelID),
                                 legacy: defaults.string(forKey: Keys.selectedModel))
        }
        set { defaults.set(newValue.storageKey, forKey: Keys.selectedModelID) }
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

    public var historyEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.historyEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.historyEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.historyEnabled) }
    }

    public var maxHistoryItems: Int {
        get {
            let val = defaults.integer(forKey: Keys.maxHistoryItems)
            return val > 0 ? val : 20
        }
        set { defaults.set(newValue, forKey: Keys.maxHistoryItems) }
    }

    /// Whether the user wants the app to open at login. Defaults to off; the
    /// user opts in from the menu bar. Only takes effect for an installed
    /// `.app` bundle (see `LoginItemManager`).
    public var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set { defaults.set(newValue, forKey: Keys.launchAtLogin) }
    }

    /// Keep each recording and the text the engine produced for it in
    /// `~/Library/Application Support/VoiceDictation/comparison/`, for the
    /// engine comparison. Defaults to off.
    public var keepComparisonRecordings: Bool {
        get { defaults.bool(forKey: Keys.keepComparisonRecordings) }
        set { defaults.set(newValue, forKey: Keys.keepComparisonRecordings) }
    }

    /// How many recent recordings the app keeps for replay and
    /// re-transcription. 0 keeps none for new dictations; failed and pinned
    /// ones are always kept and not counted (`TranscriptStore.prune`).
    public static let defaultKeptRecordings = 50

    public var keptRecordings: Int {
        get {
            guard defaults.object(forKey: Keys.keptRecordings) != nil else { return Self.defaultKeptRecordings }
            return max(0, defaults.integer(forKey: Keys.keptRecordings))
        }
        set { defaults.set(max(0, newValue), forKey: Keys.keptRecordings) }
    }

    /// True once the app has been started before; the Welcome window shows
    /// itself on the first launch whatever else is set up.
    public var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Keys.hasLaunchedBefore) }
        set { defaults.set(newValue, forKey: Keys.hasLaunchedBefore) }
    }

    /// True once a dictation has pasted: the Welcome window's last step.
    public var onboardingTriedIt: Bool {
        get { defaults.bool(forKey: Keys.onboardingTriedIt) }
        set { defaults.set(newValue, forKey: Keys.onboardingTriedIt) }
    }

    /// "Clean up transcripts": dictations are cleaned up on the Mac before
    /// they paste (Task 21). On until switched off; while Apple Intelligence
    /// is unavailable the cleaner is skipped whatever this says.
    public var cleanupEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.cleanupEnabled) != nil else { return true }
            return defaults.bool(forKey: Keys.cleanupEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.cleanupEnabled) }
    }

    /// The key held to dictate (Task 23), saved by its raw value. Globe
    /// until another is chosen; a saved value this version does not know
    /// reads as Globe. The event tap reads it when it starts.
    public var hotkey: HotkeyChoice {
        get { defaults.string(forKey: Keys.hotkey).flatMap(HotkeyChoice.init(rawValue:)) ?? .globe }
        set { defaults.set(newValue.rawValue, forKey: Keys.hotkey) }
    }

    /// Hands-free lock: a quick double tap of the hotkey records until the
    /// next press (Task 23). Off until switched on; read at each press.
    public var handsFreeEnabled: Bool {
        get { defaults.bool(forKey: Keys.handsFreeEnabled) }
        set { defaults.set(newValue, forKey: Keys.handsFreeEnabled) }
    }

    /// Control-Option-V pastes the last transcript, as the menu's Paste Last
    /// Transcript does (Task 23). Off until switched on; read at each key.
    public var pasteLastHotkeyEnabled: Bool {
        get { defaults.bool(forKey: Keys.pasteLastHotkeyEnabled) }
        set { defaults.set(newValue, forKey: Keys.pasteLastHotkeyEnabled) }
    }

    /// The app uses `shared`, on the standard defaults.
    init(defaults: PreferenceStore = UserDefaults.standard) {
        self.defaults = defaults
    }
}
