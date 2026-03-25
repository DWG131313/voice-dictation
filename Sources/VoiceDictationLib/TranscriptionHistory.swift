import Foundation

public struct TranscriptionEntry: Codable {
    public let text: String
    public let timestamp: Date
    public let modelId: String

    public init(text: String, timestamp: Date = Date(), modelId: String = PreferencesManager.shared.selectedModelId) {
        self.text = text
        self.timestamp = timestamp
        self.modelId = modelId
    }
}

public class TranscriptionHistory {
    private let storageURL: URL
    private let maxItems: Int
    public private(set) var entries: [TranscriptionEntry] = []

    public init(storageURL: URL? = nil, maxItems: Int? = nil) {
        if let url = storageURL {
            self.storageURL = url
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("VoiceDictation")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storageURL = dir.appendingPathComponent("history.json")
        }
        self.maxItems = maxItems ?? PreferencesManager.shared.maxHistoryItems
        load()
    }

    public func add(text: String) {
        let entry = TranscriptionEntry(text: text)
        entries.insert(entry, at: 0)

        // Trim to max
        if entries.count > maxItems {
            entries = Array(entries.prefix(maxItems))
        }

        save()
    }

    public func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([TranscriptionEntry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
