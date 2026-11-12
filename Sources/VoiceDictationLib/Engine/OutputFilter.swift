import Foundation

/// Cleans raw engine output. Every engine's text goes through here, so a
/// silence hallucination is dropped no matter which engine produced it.
public enum OutputFilter {
    /// Tokens whisper emits for non-speech audio. A line that is nothing but
    /// one of these is dropped so silence never pastes "[BLANK_AUDIO]".
    private static let nonSpeechLine = try! NSRegularExpression(
        pattern: #"^\s*(\[[^\]]*\]|\([^)]*\)|\*[^*]*\*)\s*$"#
    )

    /// A leading whisper timestamp: `[00:00:00.000 --> 00:00:03.000]`
    private static let leadingTimestamp = try! NSRegularExpression(
        pattern: #"^\s*\[\d{2}:\d{2}:\d{2}\.\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}\.\d{3}\]"#
    )

    /// Whole-transcript outputs whisper produces from silence or breath noise.
    /// Compared after lowercasing and stripping punctuation, and only against
    /// the entire transcript, so real sentences are never touched.
    private static let silenceHallucinations: Set<String> = [
        "you", "thank you", "thanks for watching", "thank you for watching",
        "thanks for listening", "bye", "the end",
    ]

    public static func clean(_ engineOutput: String) -> String {
        let text = joinLines(engineOutput)
        let normalized = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if silenceHallucinations.contains(normalized) { return "" }
        return text
    }

    private static func joinLines(_ output: String) -> String {
        var result: [String] = []

        for line in output.components(separatedBy: .newlines) {
            var cleaned = line

            // Strip a leading timestamp only — never brackets inside the text.
            let full = NSRange(cleaned.startIndex..., in: cleaned)
            if let match = leadingTimestamp.firstMatch(in: cleaned, range: full),
               let range = Range(match.range, in: cleaned) {
                cleaned.removeSubrange(range)
            }

            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            if cleaned.isEmpty { continue }

            let range = NSRange(cleaned.startIndex..., in: cleaned)
            if nonSpeechLine.firstMatch(in: cleaned, range: range) != nil { continue }

            result.append(cleaned)
        }

        return result.joined(separator: " ")
    }
}
