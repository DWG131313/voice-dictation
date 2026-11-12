import SwiftUI
import VoiceDictationLib

/// The floating indicator's box: "Listening" with the live volume line, the
/// time and "esc to cancel" while recording, then "Transcribing" or "Cleaning
/// up", and nothing in any other state. Black, a 1 pt hairline, square corners
/// and no colour (Prism). With Reduce Motion on, the line holds flat and only
/// the words and the timer change.
public struct IndicatorView: View {
    private let state: DictationState
    private let level: LevelLine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: DictationState, level: LevelLine) {
        self.state = state
        self.level = level
    }

    public var body: some View {
        if let words = Self.words(for: state) {
            HStack(spacing: 14) {
                Text(words)
                    .font(Theme.Font.ui(13, medium: true))
                if case .recording(let since) = state {
                    line
                    timer(since: since)
                    Text("esc to cancel")
                        .font(Theme.Font.mono(12))
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
            .foregroundStyle(Theme.Color.text)
            // As tall as the line in every state, so the box keeps its height
            // when the words change.
            .frame(height: LevelLine.height)
            // The prototype's 11 by 18 points inside a 1 pt border.
            .padding(.vertical, 12)
            .padding(.horizontal, 19)
            .background(Theme.Color.bg)
            .overlay(Rectangle().strokeBorder(Theme.Color.hairline, lineWidth: 1))
        }
    }

    /// What the indicator says in `state`, or nil when it is hidden.
    static func words(for state: DictationState) -> String? {
        switch state {
        case .recording: "Listening"
        case .transcribing: "Transcribing"
        case .cleaning: "Cleaning up"
        case .idle, .preparingModel, .needsPermission, .error: nil
        }
    }

    /// `m:ss` for a recording `elapsed` seconds old, counting whole seconds.
    static func clock(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed.rounded(.down)))
        let seconds = total % 60
        return "\(total / 60):\(seconds < 10 ? "0" : "")\(seconds)"
    }

    /// The live line: a 1 pt white polyline with mitred corners, drawn every
    /// frame; flat with Reduce Motion on.
    private var line: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let points = reduceMotion ? Self.flatLine : level.points(at: Self.uptime(at: timeline.date))
                // The first and last vertices lie just outside the canvas.
                context.clip(to: Path(CGRect(origin: .zero, size: size)))
                context.stroke(Path { $0.addLines(points) }, with: .color(.white),
                               style: StrokeStyle(lineWidth: 1, lineJoin: .miter, miterLimit: 10))
            }
        }
        .frame(width: LevelLine.width, height: LevelLine.height)
        .accessibilityHidden(true)
    }

    /// The time since the recording started. The timeline ticks on each whole
    /// second after `since`.
    private func timer(since: Date) -> some View {
        TimelineView(.periodic(from: since, by: 1)) { timeline in
            Text(Self.clock(timeline.date.timeIntervalSince(since)))
                .font(Theme.Font.mono(12))
        }
    }

    private static let flatLine = [CGPoint(x: 0, y: LevelLine.height / 2),
                                   CGPoint(x: LevelLine.width, y: LevelLine.height / 2)]

    /// A frame's date on the clock the line's peaks are timed by
    /// (`systemUptime`, which changes to the wall clock do not move).
    private static func uptime(at date: Date) -> TimeInterval {
        ProcessInfo.processInfo.systemUptime + date.timeIntervalSinceNow
    }
}
