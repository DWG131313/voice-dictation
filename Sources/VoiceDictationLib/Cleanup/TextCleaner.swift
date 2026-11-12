import Foundation

/// Tidies a dictation's raw text before it is pasted: removes filler words,
/// fixes punctuation and capitalisation, and changes nothing else. Task 21
/// adds the on-device implementation and the guard that checks its work;
/// until then the app has no cleaner and pastes the raw text.
public protocol TextCleaner: Sendable {
    func clean(_ raw: String) async throws -> String
}
