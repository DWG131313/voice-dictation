import Foundation

/// While "Keep recordings for comparison" is on, keeps each dictation's
/// recording and the model's text for it in
/// `~/Library/Application Support/VoiceDictation/comparison/`, for the engine
/// comparison (D1, Task 10). Task 24 replaces this with the audio archive.
struct ComparisonRecordings {
    let directory: URL
    private let preferences: PreferencesManager
    private let queue: DispatchQueue

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceDictation/comparison", isDirectory: true)
    }

    /// Tests pass a directory of their own, preferences kept in memory, and
    /// a queue they can wait on.
    init(directory: URL = Self.defaultDirectory, preferences: PreferencesManager = .shared,
         queue: DispatchQueue = DispatchQueue(label: "VoiceDictation.comparison", qos: .utility)) {
        self.directory = directory
        self.preferences = preferences
        self.queue = queue
    }

    /// Writes `<stem>.wav` and `<stem>.txt`, holding the model's raw text
    /// (empty for a failure), on a queue of its own so no dictation waits for
    /// it. Writes nothing while the setting is off or without a clip.
    func keep(_ outcome: DictationOutcome) {
        guard preferences.keepComparisonRecordings, let clip = outcome.clip else { return }
        let directory = self.directory
        let stem = Self.stem(for: outcome.date)
        let text = outcome.rawText
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try clip.writeWAV(to: directory.appendingPathComponent("\(stem).wav"))
                try text.write(to: directory.appendingPathComponent("\(stem).txt"), atomically: true, encoding: .utf8)
            } catch {
                Log.info("[COMPARE] Could not keep recording \(stem): \(error.localizedDescription)")
            }
        }
    }

    /// Unix time in milliseconds: the name the `.wav` and `.txt` share.
    static func stem(for date: Date) -> String {
        String(Int(date.timeIntervalSince1970 * 1000))
    }
}
