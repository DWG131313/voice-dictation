import Foundation

/// Turns `vd-bench` measurements into the engine comparison report. Pure:
/// no engines, no files.
public enum BenchReport {
    /// One model's result for one clip.
    public struct Row: Equatable {
        public let clip: String
        public let audioSeconds: Double
        /// `ModelID.storageKey`, e.g. `whisperKit/tiny.en`.
        public let model: String
        public let text: String
        public let seconds: Double
        /// Set when the engine threw; such a row is shown but not timed.
        public let failure: String?

        public init(clip: String, audioSeconds: Double, model: String, text: String,
                    seconds: Double, failure: String? = nil) {
            self.clip = clip
            self.audioSeconds = audioSeconds
            self.model = model
            self.text = text
            self.seconds = seconds
            self.failure = failure
        }
    }

    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Both texts with the words that differ in bold. Neighbouring changed
    /// words share one pair of asterisks.
    public static func diffWords(_ a: String, _ b: String) -> (String, String) {
        let wordsA = words(a), wordsB = words(b)
        let (markedA, markedB) = changedIndices(wordsA, wordsB)
        return (render(wordsA, marked: markedA), render(wordsB, marked: markedB))
    }

    public static func markdown(rows: [Row], loadSeconds: [String: Double] = [:],
                                skipped: [String: String] = [:]) -> String {
        var models: [String] = []
        var clips: [String] = []
        for row in rows {
            if !models.contains(row.model) { models.append(row.model) }
            if !clips.contains(row.clip) { clips.append(row.clip) }
        }

        var out = "# Engine comparison\n\n"
        out += "| Model | Median seconds | Median seconds per second of audio | Clips |\n|---|---|---|---|\n"
        for model in models {
            let timed = rows.filter { $0.model == model && $0.failure == nil }
            let perAudio = timed.filter { $0.audioSeconds > 0 }.map { $0.seconds / $0.audioSeconds }
            out += "| \(model) | \(format(median(timed.map(\.seconds)), 2)) | \(format(median(perAudio), 3)) | \(timed.count) |\n"
        }

        out += "\nLoad time, reported apart from the table above. The first clip of each model was transcribed once and discarded.\n\n"
        out += "| Model | Load seconds |\n|---|---|\n"
        for model in models {
            out += "| \(model) | \(loadSeconds[model].map { format($0, 2) } ?? "n/a") |\n"
        }

        if !skipped.isEmpty {
            out += "\nSkipped:\n\n"
            for (model, reason) in skipped.sorted(by: { $0.key < $1.key }) { out += "- \(model): \(reason)\n" }
        }

        for clip in clips {
            let clipRows = rows.filter { $0.clip == clip }
            out += "\n## \(clip)\n\n"
            let marked = markedWords(clipRows)
            for (row, indices) in zip(clipRows, marked) {
                let text = row.failure.map { "failed: \($0)" } ?? render(words(row.text), marked: indices)
                let time = row.failure == nil ? " (\(format(row.seconds, 2)) s)" : ""
                out += "- \(row.model)\(time): \(text)\n"
            }
        }
        return out
    }

    // MARK: - Diffing

    /// For each row, the word positions that differ from at least one other
    /// successful row of the same clip.
    private static func markedWords(_ rows: [Row]) -> [Set<Int>] {
        let split = rows.map { words($0.text) }
        return rows.indices.map { i in
            guard rows[i].failure == nil else { return [] }
            var marked = Set<Int>()
            for j in rows.indices where j != i && rows[j].failure == nil {
                marked.formUnion(changedIndices(split[i], split[j]).0)
            }
            return marked
        }
    }

    private static func changedIndices(_ a: [String], _ b: [String]) -> (Set<Int>, Set<Int>) {
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        return (removed, inserted)
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func render(_ words: [String], marked: Set<Int>) -> String {
        var pieces: [String] = []
        var run: [String] = []
        func flush() {
            if !run.isEmpty { pieces.append("**\(run.joined(separator: " "))**") }
            run = []
        }
        for (i, word) in words.enumerated() {
            if marked.contains(i) {
                run.append(word)
            } else {
                flush()
                pieces.append(word)
            }
        }
        flush()
        return pieces.joined(separator: " ")
    }

    private static func format(_ value: Double, _ places: Int) -> String {
        String(format: "%.\(places)f", value)
    }
}
