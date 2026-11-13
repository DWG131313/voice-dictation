import Foundation
import Observation

/// Danny's own words and replacement rules, kept in `vocabulary.json` in the
/// app's data folder. Words go to the engines that can use them as a hint
/// (Apple Dictation, WhisperKit, whisper.cpp; Apple Speech ignores them);
/// the rules change the text after any engine. Use from the main thread.
///
/// The lists are held as rows with identities (`wordRows`, `ruleRows`), so a
/// list in a view can follow a row while others are removed; `words` and
/// `replacements` are the plain values, which is also what the file holds.
@MainActor @Observable
public final class VocabularyStore {
    public struct WordRow: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var text: String
        public init(id: UUID = UUID(), text: String) {
            self.id = id
            self.text = text
        }
    }

    public struct RuleRow: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var from: String
        public var to: String
        public init(id: UUID = UUID(), from: String, to: String) {
            self.id = id
            self.from = from
            self.to = to
        }
    }

    public var wordRows: [WordRow]
    public var ruleRows: [RuleRow]

    /// The words as plain strings. Setting them makes new rows.
    public var words: [String] {
        get { wordRows.map(\.text) }
        set { wordRows = newValue.map { WordRow(text: $0) } }
    }

    /// The rules as plain values. Setting them makes new rows.
    public var replacements: [Replacement] {
        get { ruleRows.map { Replacement(from: $0.from, to: $0.to) } }
        set { ruleRows = newValue.map { RuleRow(from: $0.from, to: $0.to) } }
    }

    @ObservationIgnored private let fileURL: URL
    /// False after an error reading the file, or moving a bad one aside:
    /// whatever is there stays, untouched, for the session.
    @ObservationIgnored private var canSave = true

    private struct File: Codable {
        var words: [String]
        var replacements: [Replacement]
    }

    /// Loads `fileURL`. No file gives empty lists. A file that is there but
    /// cannot be decoded is moved aside as `vocabulary.json.broken-<stamp>`
    /// (as the transcript store does) and the lists start empty. A file that
    /// cannot be read at all is left where it is and nothing is saved this
    /// session, so a passing error cannot destroy it.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        wordRows = []
        ruleRows = []
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            Log.info("[VOCAB] Could not read \(fileURL.lastPathComponent); leaving it alone: \(error)")
            canSave = false
            return
        }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            words = Self.tidy(file.words)
            replacements = Self.tidy(file.replacements)
        } catch {
            let target = URL(fileURLWithPath: fileURL.path + TranscriptStore.brokenSuffix(at: Date()))
            do {
                try FileManager.default.moveItem(at: fileURL, to: target)
                Log.info("[VOCAB] \(fileURL.lastPathComponent) was not valid; moved it aside as \(target.lastPathComponent)")
            } catch {
                Log.info("[VOCAB] \(fileURL.lastPathComponent) was not valid and could not be moved aside: \(error)")
                canSave = false
            }
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
        wordRows.append(WordRow(text: word))
        return true
    }

    public func addReplacement(from: String, to: String) {
        ruleRows.append(RuleRow(from: from, to: to))
    }

    /// Removes a row by identity; a row already gone is not an error.
    public func removeWord(id: UUID) {
        wordRows.removeAll { $0.id == id }
    }

    public func removeRule(id: UUID) {
        ruleRows.removeAll { $0.id == id }
    }

    /// Writes the tidied lists atomically. Rows being edited stay as they
    /// are in memory, blank ones included, so a field cleared to be retyped
    /// does not vanish; they are gone at the next launch. A failure is logged.
    public func save() {
        guard canSave else { return }
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
