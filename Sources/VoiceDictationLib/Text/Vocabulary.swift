import Foundation
import Observation

/// Danny's own words and replacement rules, kept in `vocabulary.json` in the
/// app's data folder. Words go to the engines that can use them as a hint
/// (Apple Dictation, WhisperKit, whisper-cli; Apple Speech ignores them);
/// the rules change the text after any engine. Use from the main thread.
@MainActor @Observable
public final class VocabularyStore {
    public var words: [String]
    public var replacements: [Replacement]

    @ObservationIgnored private let fileURL: URL

    private struct File: Codable {
        var words: [String]
        var replacements: [Replacement]
    }

    /// Loads `fileURL`. A missing or unreadable file gives empty lists; an
    /// unreadable one is left where it is until the next `save()`.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(File.self, from: data) {
            words = Self.tidy(file.words)
            replacements = Self.tidy(file.replacements)
        } else {
            words = []
            replacements = []
        }
    }

    /// The words to hand an engine: trimmed, no blanks, no repeats (any case).
    public var activeWords: [String] { Self.tidy(words) }

    /// The rules to apply: those with something to match.
    public var activeReplacements: [Replacement] { Self.tidy(replacements) }

    /// Adds a word unless it is blank or already there (any case); true if added.
    @discardableResult
    public func addWord(_ word: String) -> Bool {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !words.contains(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(word) == .orderedSame })
        else { return false }
        words.append(word)
        return true
    }

    /// Writes the tidied lists atomically. Rows being edited stay as they
    /// are in memory, blank ones included, so a field cleared to be retyped
    /// does not vanish; they are gone at the next launch. A failure is logged.
    public func save() {
        let words = activeWords, replacements = activeReplacements
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(File(words: words, replacements: replacements)).write(to: fileURL, options: .atomic)
        } catch {
            Log.info("[VOCAB] Could not save \(fileURL.lastPathComponent): \(error)")
        }
    }

    private static func tidy(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private static func tidy(_ rules: [Replacement]) -> [Replacement] {
        rules.compactMap { rule in
            let from = rule.from.trimmingCharacters(in: .whitespacesAndNewlines)
            return from.isEmpty ? nil : Replacement(from: from, to: rule.to)
        }
    }
}
