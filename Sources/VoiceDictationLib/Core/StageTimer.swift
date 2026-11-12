import Foundation

/// Marks the moments of one dictation so each stage can be timed.
public struct StageTimer {
    public enum Stage: Hashable {
        case keyDown, firstAudio, keyUp, textReady, cleaned, pasted
    }

    private var marks: [Stage: Date] = [:]

    public init() {}

    public mutating func mark(_ stage: Stage, at: Date = Date()) {
        marks[stage] = at
    }

    /// Whole milliseconds from one mark to another, nil if either is missing.
    public func milliseconds(from: Stage, to: Stage) -> Int? {
        guard let start = marks[from], let end = marks[to] else { return nil }
        return Int((end.timeIntervalSince(start) * 1000).rounded())
    }

    /// One line, e.g. `keyDown→firstAudio=120ms keyUp→text=800ms text→pasted=15ms`.
    /// Intervals with a missing mark are left out.
    public var summary: String {
        let parts: [(String, Stage, Stage)] = [
            ("keyDown→firstAudio", .keyDown, .firstAudio),
            ("keyUp→text", .keyUp, .textReady),
            ("text→pasted", .textReady, .pasted),
        ]
        return parts.compactMap { name, from, to in
            milliseconds(from: from, to: to).map { "\(name)=\($0)ms" }
        }.joined(separator: " ")
    }
}
