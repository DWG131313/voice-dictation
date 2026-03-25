import Foundation

public class PreferencesManager {
    public static let shared = PreferencesManager()

    private let defaults = UserDefaults.standard

    // MARK: - Keys
    private enum Keys {
        static let selectedModel = "selectedModel"
        static let historyEnabled = "historyEnabled"
        static let maxHistoryItems = "maxHistoryItems"
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

    private init() {}
}
