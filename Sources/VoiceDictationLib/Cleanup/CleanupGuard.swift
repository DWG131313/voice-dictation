import Foundation

/// Decides whether a cleanup only did what cleanup may do: delete fillers and
/// stammers, and change case and punctuation. Any other change, an added,
/// changed or reordered word, or a deleted word that is not a filler, rejects
/// it, and the raw text is pasted instead (Review Focus 3).
///
/// "right", "so", "like" and "you know" are fillers only some of the time,
/// so they may go only where the speech marks them as fillers: set off by a
/// pause mark, or next to an "um". False starts stay in (Danny, 2026-11-11):
/// removing one deletes real words.
public enum CleanupGuard {
    /// Sounds that are never words: deletable anywhere.
    public static let disfluencies: Set<String> = ["um", "uh", "uhm", "er", "erm", "ah", "hmm", "mm"]

    /// Words and phrases that are fillers only when set off (rule 4 of
    /// `accepts`). The phrases come first, so the longest filler is tried first.
    public static let discourseFillers: [[String]] = [
        ["you", "know"], ["i", "mean"], ["kind", "of"], ["sort", "of"],
        ["like"], ["so"], ["well"], ["okay"], ["ok"], ["right"], ["actually"], ["basically"], ["literally"],
    ]

    /// A word of a text, as the guard compares them, and whether a pause mark
    /// stands between it and the word before or after it.
    public struct Token: Equatable, Sendable {
        public let word: String
        public let pauseBefore: Bool
        public let pauseAfter: Bool
    }

    /// The text's words, lowercased, with apostrophes and hyphens removed
    /// ("It's e-mail" is `its`, `email`); any other character that is not a
    /// letter or a digit separates words. A comma, a dash (— or –) or an
    /// ellipsis (… or ...) between two words is a pause, marked on both;
    /// there is none before the first word or after the last.
    public static func tokens(_ s: String) -> [Token] {
        var words: [String] = []
        // `gaps[i]` is the text between `words[i - 1]` and `words[i]`.
        var gaps: [String] = []
        var word = ""
        var gap = ""
        for character in s.lowercased() where !joiners.contains(character) {
            if character.isLetter || character.isNumber {
                if word.isEmpty {
                    gaps.append(gap)
                    gap = ""
                }
                word.append(character)
            } else {
                if !word.isEmpty {
                    words.append(word)
                    word = ""
                }
                gap.append(character)
            }
        }
        if !word.isEmpty { words.append(word) }
        return words.indices.map { i in
            Token(word: words[i],
                  pauseBefore: i > 0 && isPause(gaps[i]),
                  pauseAfter: i + 1 < words.count && isPause(gaps[i + 1]))
        }
    }

    /// Whether `cleaned` is a cleanup of `raw` that may be pasted. With `r`
    /// and `c` the two texts' words, it accepts only if all of these hold:
    ///
    /// 1. `c` is not empty.
    /// 2. `c` is a subsequence of `r`, matched leftmost-first: cleanup may
    ///    delete words, never add, change or reorder them.
    /// 3. Reading each run of consecutive deleted words left to right, every
    ///    word is, checked in this order, a disfluency, a stammer (the same
    ///    word repeated next to itself, skipping disfluencies in between,
    ///    with at least one copy kept), or part of a discourse filler. A
    ///    filler phrase counts only when the whole phrase is in the run.
    /// 4. A run that uses a discourse filler is set off: it also contains a
    ///    disfluency, or a pause comes before its first word or after its last.
    /// 5. At most 40% of `r` is deleted.
    public static func accepts(raw: String, cleaned: String) -> Bool {
        let r = tokens(raw)
        let c = tokens(cleaned).map(\.word)
        guard !c.isEmpty else { return false }                                     // 1
        guard let kept = leftmostMatch(of: c, in: r.map(\.word)) else { return false }  // 2
        let deleted = r.indices.filter { !kept.contains($0) }
        guard deleted.count * 5 <= r.count * 2 else { return false }               // 5
        return runs(of: deleted).allSatisfy { isFiller($0, in: r, kept: kept) }    // 3 and 4
    }

    // MARK: - The rule's parts

    /// Removed before the words are read, so they join what they sit in.
    private static let joiners: Set<Character> = ["'", "’", "‘", "ʼ", "-", "‐", "‑"]

    private static func isPause(_ gap: String) -> Bool {
        gap.contains(",") || gap.contains("—") || gap.contains("–") || gap.contains("…") || gap.contains("...")
    }

    /// The indices of `words` that keep `wanted`, each matched to the first
    /// word left that equals it; nil when `wanted` is not a subsequence.
    private static func leftmostMatch(of wanted: [String], in words: [String]) -> Set<Int>? {
        var kept: Set<Int> = []
        var next = 0
        for (index, word) in words.enumerated() where next < wanted.count && word == wanted[next] {
            kept.insert(index)
            next += 1
        }
        return next == wanted.count ? kept : nil
    }

    /// Sorted indices, split into runs of consecutive ones.
    private static func runs(of indices: [Int]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        for index in indices {
            if let last = runs.last, last.upperBound == index {
                runs[runs.count - 1] = last.lowerBound..<(index + 1)
            } else {
                runs.append(index..<(index + 1))
            }
        }
        return runs
    }

    /// Rules 3 and 4 for one run of deleted words.
    private static func isFiller(_ run: Range<Int>, in r: [Token], kept: Set<Int>) -> Bool {
        var usesDiscourseFiller = false
        var hasDisfluency = false
        var k = run.lowerBound
        while k < run.upperBound {
            if disfluencies.contains(r[k].word) {
                hasDisfluency = true
                k += 1
            } else if isStammer(k, in: r, kept: kept) {
                k += 1
            } else if let phrase = discourseFillers.first(where: { startsAt(k, $0, within: run, in: r) }) {
                usesDiscourseFiller = true
                k += phrase.count
            } else {
                return false
            }
        }
        guard usesDiscourseFiller, !hasDisfluency else { return true }
        return r[run.lowerBound].pauseBefore || r[run.upperBound - 1].pauseAfter
    }

    /// Whether `r[k]` repeats a kept copy of itself next to it, either way,
    /// across other copies and disfluencies. The raw words decide, not which
    /// copy the match kept: a leftmost match keeps the first.
    private static func isStammer(_ k: Int, in r: [Token], kept: Set<Int>) -> Bool {
        let word = r[k].word
        for step in [-1, 1] {
            var j = k + step
            while r.indices.contains(j), r[j].word == word || disfluencies.contains(r[j].word) {
                if r[j].word == word, kept.contains(j) { return true }
                j += step
            }
        }
        return false
    }

    /// Whether the whole of `phrase` stands at `k`, inside the run.
    private static func startsAt(_ k: Int, _ phrase: [String], within run: Range<Int>, in r: [Token]) -> Bool {
        guard k + phrase.count <= run.upperBound else { return false }
        return phrase.indices.allSatisfy { r[k + $0].word == phrase[$0] }
    }
}
