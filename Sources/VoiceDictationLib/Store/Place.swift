import Foundation

/// Where a dictation was made: the app, and the folder its window was open
/// on. An empty name reads as none, for both.
public struct Place: Hashable, Sendable {
    public let app: String?
    public let project: String?

    public init(app: String?, project: String?) {
        self.app = Self.name(app)
        self.project = Self.name(project)
    }

    public init(_ t: Transcript) {
        self.init(app: t.appName, project: t.project)
    }

    private static func name(_ s: String?) -> String? {
        s?.isEmpty == false ? s : nil
    }
}

/// Which places a search looks at.
public enum PlaceFilter: Hashable, Sendable {
    /// Every transcript from that app; nil: the app is unknown.
    case app(String?)
    /// Exactly that app and folder; a nil project: none recorded.
    case place(Place)

    public func matches(_ t: Transcript) -> Bool {
        let place = Place(t)
        switch self {
        case .app(let app): return place.app == Place(app: app, project: nil).app
        case .place(let wanted): return place == wanted
        }
    }
}

/// How many transcripts a place holds.
public struct PlaceCount: Equatable, Sendable {
    public let place: Place
    public let count: Int

    public init(place: Place, count: Int) {
        self.place = place
        self.count = count
    }
}

/// How long a recording is. A transcript without a recording (0 s) is in
/// none but `.any`.
public enum LengthFilter: String, CaseIterable, Sendable {
    case any, short, medium, long

    /// short: 0 < s < 10; medium: 10 ≤ s < 60; long: s ≥ 60.
    public func contains(_ seconds: Double) -> Bool {
        switch self {
        case .any: return true
        case .short: return seconds > 0 && seconds < 10
        case .medium: return seconds >= 10 && seconds < 60
        case .long: return seconds >= 60
        }
    }
}
