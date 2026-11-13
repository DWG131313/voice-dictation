import Foundation

/// One of Danny's corrections: wherever a dictation says `from`, paste `to`.
/// `Replacements.apply` applies them; `VocabularyStore` keeps them.
public struct Replacement: Codable, Equatable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Applies Danny's replacement rules to a text. Pure: no state, no I/O.
public enum Replacements {
    /// `text` with every rule's `from` swapped for its `to`. A match is
    /// case-insensitive and whole-word (or whole-phrase: any run of spaces
    /// inside `from` matches any run of whitespace). The longest `from`
    /// wins where several match at one place, and among equal ones the
    /// first rule does. Each stretch of text is replaced at most once, so a
    /// replacement is never matched again, and `to` goes in exactly as
    /// written. A rule with a blank `from` does nothing.
    public static func apply(_ rules: [Replacement], to text: String) -> String {
        // The regex alternation tries its parts in order, so longest first;
        // the sort is stable, so equal lengths keep the rules' order.
        var seen = Set<String>()
        var usable: [Replacement] = []
        for rule in rules {
            let from = rule.from.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty, seen.insert(from.lowercased()).inserted else { continue }
            usable.append(Replacement(from: from, to: rule.to))
        }
        guard !usable.isEmpty else { return text }
        usable = usable.enumerated()
            .sorted { ($0.element.from.count, $1.offset) > ($1.element.from.count, $0.offset) }
            .map(\.element)

        let parts = usable.map { rule in
            rule.from.split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s+")
        }
        let wordCharacter = "[\\p{L}\\p{N}_]"
        let pattern = "(?<!\(wordCharacter))(?:\(parts.joined(separator: "|")))(?!\(wordCharacter))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }

        let source = text as NSString
        var result = ""
        var position = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: position, length: match.range.location - position))
            let found = source.substring(with: match.range)
            result += rule(matching: found, in: usable)?.to ?? found
            position = match.range.location + match.range.length
        }
        result += source.substring(from: position)
        return result
    }

    /// The rule that matched `found`: the first, longest, whose `from`
    /// matches it whole (so equal-length rules cannot be mixed up).
    private static func rule(matching found: String, in rules: [Replacement]) -> Replacement? {
        let normalized = found.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return rules.first { rule in
            let from = rule.from.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return from.compare(normalized, options: .caseInsensitive) == .orderedSame
        }
    }
}
