import Foundation

/// A dictation handed to the transcriber and not yet finished.
public struct PendingDictation {
    public var timer: StageTimer
    /// Millisecond Unix time naming the kept `.wav`/`.txt` pair; nil when not keeping.
    public var comparisonStem: String?
    public let fileURL: URL

    public init(timer: StageTimer, comparisonStem: String? = nil, fileURL: URL) {
        self.timer = timer
        self.comparisonStem = comparisonStem
        self.fileURL = fileURL
    }
}

/// Dictations waiting on the transcriber, in the order it finishes them.
public struct PendingDictations {
    public private(set) var items: [PendingDictation] = []

    public init() {}

    public mutating func append(_ item: PendingDictation) { items.append(item) }

    /// The oldest entry, for a completion or failure callback.
    public mutating func popFirst() -> PendingDictation? {
        items.isEmpty ? nil : items.removeFirst()
    }

    /// Removes the entry for a recording the transcriber dropped.
    public mutating func remove(fileURL: URL) { items.removeAll { $0.fileURL == fileURL } }

    public mutating func setStem(_ stem: String, for fileURL: URL) {
        if let i = items.firstIndex(where: { $0.fileURL == fileURL }) { items[i].comparisonStem = stem }
    }

    /// Forget everything; used when the transcriber is discarded and its
    /// callbacks will never arrive.
    public mutating func reset() { items.removeAll() }
}
