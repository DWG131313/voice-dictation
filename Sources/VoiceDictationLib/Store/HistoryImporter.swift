import Foundation

/// Brings the old app's `history.json` into the transcript store once, on
/// the new app's first launch, and leaves the file exactly as it was.
@MainActor
public enum HistoryImporter {
    /// Set in the preferences once every entry of `history.json` is in the store.
    static let doneKey = "didImportLegacyHistory"

    /// Imports the entries of the file at `jsonURL` unless an import already
    /// finished. Returns how many transcripts it added.
    public static func importIfNeeded(from jsonURL: URL, into store: TranscriptStore, defaults: UserDefaults) -> Int {
        importIfNeeded(from: jsonURL, into: store, preferences: defaults)
    }

    /// Each entry becomes a pasted transcript of its old whisper-cli model.
    /// The import is marked done only when every entry is in the store, so a
    /// missing or unreadable file, or an unavailable store (no `container`),
    /// is tried again at the next launch. A store started afresh after a
    /// damaged one was moved aside (`.recovered`) works, so it takes the
    /// import at once. Entries already in the store, the same time and raw
    /// text, are skipped: the done flag lives in the defaults of the binary
    /// that imported, and the bare dev binary and the app bundle (Task 13)
    /// keep different ones. Tests pass preferences kept in memory (Ruling
    /// T11-1).
    static func importIfNeeded(from jsonURL: URL, into store: TranscriptStore, preferences: PreferenceStore) -> Int {
        guard !preferences.bool(forKey: doneKey), store.container != nil,
              FileManager.default.fileExists(atPath: jsonURL.path) else { return 0 }
        let entries: [TranscriptionEntry]
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([TranscriptionEntry].self, from: Data(contentsOf: jsonURL))
        } catch {
            Log.info("[STORE] Could not read \(jsonURL.lastPathComponent) to import it: \(error)")
            return 0
        }

        let kept = Set(store.search("", scope: .all).map { Fingerprint(date: $0.date, rawText: $0.rawText) })
        var added = 0
        var complete = true
        for entry in entries where !kept.contains(Fingerprint(date: entry.timestamp, rawText: entry.text)) {
            if store.add(entry.outcome) != nil {
                added += 1
            } else {
                complete = false
            }
        }
        if complete { preferences.set(true, forKey: doneKey) }
        Log.info("[STORE] Imported \(added) of \(entries.count) transcript(s) from \(jsonURL.lastPathComponent)")
        return added
    }

    /// One entry of the old app's `history.json`, as `TranscriptionHistory`
    /// wrote it: ISO 8601 dates, newest first.
    private struct TranscriptionEntry: Decodable {
        let text: String
        let timestamp: Date
        /// The whisper-cli model, e.g. `base.en`.
        let modelId: String

        var outcome: DictationOutcome {
            DictationOutcome(date: timestamp, clip: nil, rawText: text, text: text,
                             model: ModelID(engine: .whisperCLI, name: modelId),
                             transcribeSeconds: 0, appName: nil, status: .pasted)
        }
    }

    /// What identifies an imported entry in the store; neither changes after.
    private struct Fingerprint: Hashable {
        let date: Date
        let rawText: String
    }
}
