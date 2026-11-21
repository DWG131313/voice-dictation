import CoreGraphics
import Foundation

/// The floating indicator's volume line, as the prototype draws it
/// (`prism-live-line-fluid.html`). Every `interval` the loudest peak heard
/// becomes one vertex. Vertices alternate above and below the centre and travel
/// left `step` points per interval, the newest entering on the right, so the
/// shape of what was said moves across intact. Height follows loudness: a floor
/// removes room hiss, the line rises faster than it falls so it does not
/// flicker, and a curve keeps quiet speech visible. Silence is a flat line.
///
/// A value with no clock of its own: the caller passes every time, all from one
/// monotonic clock. The app uses the mach clock `ProcessInfo.systemUptime`
/// reads: the recorder times each 50 ms slice from its buffer's host time on
/// it, and the indicator draws each frame at the present on it (Task 24A).
public struct LevelLine {
    public static let step: CGFloat = 5, interval: TimeInterval = 0.05, width: CGFloat = 170, height: CGFloat = 26
    public static let gain: Float = 5, floor: Float = 0.03, attack: Float = 0.75, release: Float = 0.35, exponent: Float = 0.7

    /// The canvas a line is drawn for: its size and how far each interval moves it.
    public struct Geometry: Equatable, Sendable {
        public let width: CGFloat, height: CGFloat, step: CGFloat

        /// Vertices kept: enough to span `width`, plus the one entering on the
        /// right and the one leaving on the left.
        var capacity: Int { Int(width / step) + 3 }

        /// The bottom pill's line.
        public static let indicator = Geometry(width: 170, height: 26, step: 5)
        /// The mini view tab's line.
        public static let tab = Geometry(width: 26, height: 18, step: 2.6)
    }

    public static let indicator = Geometry.indicator, tab = Geometry.tab

    public let geometry: Geometry

    /// Each vertex's height (-1...1), oldest first; silent (0) where nothing was heard.
    private var vertices: [Float]
    /// The interval the latest peak arrived in; nil until the first peak.
    private var current: Int?
    /// The loudest peak heard in `current`; nil until one arrives.
    private var loudest: Float?
    /// The most recent peak, which an interval that heard none repeats.
    private var held: Float = 0
    /// The side of the centre the next vertex goes.
    private var side: Float = 1
    /// The smoothed loudness at the newest vertex.
    private var envelope: Float = 0

    public init(_ geometry: Geometry = .indicator) {
        self.geometry = geometry
        vertices = [Float](repeating: 0, count: geometry.capacity)
    }

    /// Hears a peak (0...1) of audio captured at `time`: a slice's own time,
    /// never when it got here, so the vertices advance evenly however the
    /// slices bunch on the way (Task 24A). The interval keeps the loudest peak
    /// it hears and becomes one vertex once it is over. An interval that hears
    /// none repeats the most recent peak (Ruling T17-1); with a slice for every
    /// interval, that is one whose slice was lost, as with a dropped buffer. A
    /// time before the current interval counts in it.
    public mutating func add(peak: Float, at time: TimeInterval) {
        let index = max(Self.intervalIndex(at: time), current ?? .min)
        advance(to: index)
        current = index
        loudest = max(loudest ?? peak, peak)
        held = peak
    }

    /// The line at `time`: one point per vertex, oldest first, joined by
    /// straight segments. The newest is just off the right edge, and the whole
    /// line has moved left by the part of the current interval already gone.
    /// Intervals over by `time` are finished here as `add` would finish them,
    /// so the newest few, whose slices are still on their way, hold the latest
    /// peak until those arrive.
    public func points(at time: TimeInterval) -> [CGPoint] {
        var line = self
        let index = Self.intervalIndex(at: time)
        line.advance(to: index)
        let progress = CGFloat(min(max(time / Self.interval - Double(index), 0), 1))
        let mid = geometry.height / 2
        let newest = line.vertices.count - 1
        return line.vertices.enumerated().map { i, height in
            CGPoint(x: geometry.width + geometry.step - (CGFloat(newest - i) + progress) * geometry.step,
                    y: mid + CGFloat(height) * (mid - 1))
        }
    }

    /// Starts again for a new recording: flat, holding nothing, until the
    /// first peak arrives (Ruling T17-1).
    public mutating func reset() {
        self = LevelLine(geometry)
    }

    /// Finishes every interval before `index`: the one the latest peaks
    /// arrived in gives its loudest, and each after it, which heard none, the
    /// most recent peak. Nothing before the first peak.
    private mutating func advance(to index: Int) {
        guard let current, index > current else { return }
        push(loudest ?? held)
        for _ in (current + 1)..<index { push(held) }
        self.current = index
        loudest = nil
    }

    /// One finished interval whose loudest peak was `peak`: the prototype's
    /// maths, then one vertex on the right and the oldest dropped.
    private mutating func push(_ peak: Float) {
        let loud = max(0, peak * Self.gain - Self.floor)
        envelope += (loud - envelope) * (loud > envelope ? Self.attack : Self.release)
        vertices.removeFirst()
        vertices.append(side * min(1, pow(envelope, Self.exponent)))
        side = -side
    }

    private static func intervalIndex(at time: TimeInterval) -> Int {
        Int((time / interval).rounded(.down))
    }
}
