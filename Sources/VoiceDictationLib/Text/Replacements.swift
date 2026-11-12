import Foundation

/// One of Danny's corrections: wherever a dictation says `from`, paste `to`.
/// Task 22 adds the rules that apply them and the screen that edits them;
/// until then the app has none.
public struct Replacement: Codable, Equatable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}
