import Foundation

/// Tidies a dictation's raw text before it is pasted: removes filler words,
/// fixes punctuation and capitalisation, and changes nothing else. The
/// pipeline checks every result with `CleanupGuard` and pastes the raw text
/// when it changed anything more, failed, or took too long. The app's is
/// `FoundationModelCleaner`, on Apple's on-device model.
public protocol TextCleaner: Sendable {
    /// Whether it can clean now. While it cannot, the pipeline pastes the raw
    /// text without asking it.
    var isAvailable: Bool { get }
    /// Readies the model so the next `clean` starts sooner; cleans nothing.
    func prewarm()
    func clean(_ raw: String) async throws -> String
}

public extension TextCleaner {
    var isAvailable: Bool { true }
    func prewarm() {}
}
