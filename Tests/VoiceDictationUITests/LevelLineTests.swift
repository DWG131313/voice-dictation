import XCTest
@testable import VoiceDictationLib
@testable import VoiceDictationUI

/// The indicator's volume line, fed made-up peaks at made-up times.
final class LevelLineTests: XCTestCase {
    private let mid = LevelLine.height / 2

    func testSilenceIsFlat() {
        let line = fed(0, through: 0..<20)   // 1 s

        for t in [time(20), time(20) + 0.01, time(25)] {
            let points = line.points(at: t)
            XCTAssertTrue(points.allSatisfy { $0.y == mid }, "at \(t)")
            // Drawn across the whole canvas.
            XCTAssertLessThanOrEqual(points.first?.x ?? .infinity, 0)
            XCTAssertGreaterThanOrEqual(points.last?.x ?? -.infinity, LevelLine.width)
        }
    }

    func testLouderIsTaller() {
        let quiet = fed(0.02, through: 0..<20)
        let loud = fed(0.1, through: 0..<20)

        let t = time(20)
        XCTAssertGreaterThan(deviation(quiet.points(at: t)), 0, "a whisper is a ripple, not a flat line")
        XCTAssertGreaterThan(deviation(loud.points(at: t)), deviation(quiet.points(at: t)))
    }

    func testNeverExceedsBounds() {
        let line = fed(1.0, through: 0..<20)

        for t in [time(20), time(20) + 0.01, time(30)] {
            XCTAssertTrue(line.points(at: t).allSatisfy { (1...(LevelLine.height - 1)).contains($0.y) }, "at \(t)")
        }
        // Loud speech fills the bar.
        XCTAssertEqual(deviation(line.points(at: time(20))), mid - 1)
    }

    func testVerticesAlternateSides() {
        let line = fed(0.1, through: 0..<60)   // 3 s: sound across the whole line

        let below = line.points(at: time(60)).map { $0.y - mid }.filter { $0 != 0 }.map { $0 > 0 }
        XCTAssertGreaterThan(below.count, Int(LevelLine.width / LevelLine.step))
        XCTAssertTrue(zip(below, below.dropFirst()).allSatisfy { $0 != $1 }, "\(below)")
    }

    /// Each vertex keeps its side as it scrolls: one interval later every
    /// vertex is the one that was a step to its right, so the line does not flip.
    func testVerticesKeepTheirSideWhileScrolling() {
        let line = fed(0.1, through: 0..<60)

        let before = line.points(at: time(60)).map(\.y)
        let after = line.points(at: time(61)).map(\.y)
        XCTAssertEqual(before.count, after.count)
        for (b, a) in zip(before.dropFirst(), after.dropLast()) {
            XCTAssertEqual(b, a, accuracy: 1e-9)
        }
        XCTAssertNotEqual(before[1], before[2], "the neighbours are on opposite sides")
    }

    /// One loud interval between quiet ones travels left `step` points per
    /// interval, and smoothly in between.
    func testScrollsLeft() {
        var line = fed(0, through: 0..<10)
        line.add(peak: 0.2, at: time(10))
        line = fed(0, through: 11..<14, onto: line)

        let start = time(14) - 0.02   // a tenth of the way into interval 14
        let x = loudest(line.points(at: start)).x
        XCTAssertEqual(x - loudest(line.points(at: start + LevelLine.interval / 2)).x, LevelLine.step / 2, accuracy: 1e-9)
        XCTAssertEqual(x - loudest(line.points(at: start + LevelLine.interval)).x, LevelLine.step, accuracy: 1e-9)
        XCTAssertEqual(x - loudest(line.points(at: start + 3 * LevelLine.interval)).x, 3 * LevelLine.step, accuracy: 1e-9)
    }

    /// One interval of sound lifts the line further than one interval of
    /// silence lowers it, so it does not flicker. The amplitudes are pinned:
    /// from the prototype's maths, a peak of 0.1 is loud = 0.1 x gain - floor
    /// = 0.47, and the half-height is mid - 1 = 12.
    func testRisesFasterThanFalls() {
        let steady = fed(0.1, through: 0..<40)
        let rising = fed(0.1, through: 10..<11, onto: fed(0, through: 0..<10))
        let falling = fed(0, through: 40..<41, onto: steady)

        // Attack: env = 0.47 x 0.75 from silence.
        let rise = entering(rising, at: time(11))
        XCTAssertEqual(rise, 12 * CGFloat(pow(0.75 * 0.47, 0.7)), accuracy: 1e-3)   // 5.784
        // Steady 0.1 settles on env = 0.47; release: env = 0.47 x (1 - 0.35).
        XCTAssertEqual(entering(steady, at: time(40)), 12 * CGFloat(pow(0.47, 0.7)), accuracy: 1e-3)
        let fall = entering(falling, at: time(41))
        XCTAssertEqual(fall, 12 * CGFloat(pow(0.65 * 0.47, 0.7)), accuracy: 1e-3)   // 5.23
        XCTAssertGreaterThan(entering(steady, at: time(40)) - fall, 0)
        XCTAssertGreaterThan(rise, fall)
    }

    func testKeepsOnlyVisibleHistory() {
        let line = fed(0.1, through: 0..<1200)   // 60 s

        let points = line.points(at: time(1200))
        XCTAssertLessThanOrEqual(points.count, Int(LevelLine.width / LevelLine.step) + 3)
        // Still enough to cross the whole canvas.
        XCTAssertLessThanOrEqual(points.first?.x ?? .infinity, 0)
        XCTAssertGreaterThanOrEqual(points.last?.x ?? -.infinity, LevelLine.width)
    }

    /// Ruling T17-1: an interval that hears no peak holds the latest one, so
    /// a steady voice draws a steady line instead of dipping. Since Task 24A a
    /// peak comes every 50 ms, one per interval, so this is a slice that was
    /// lost; here peaks come every 100 ms, as they did before, and every other
    /// interval hears none.
    func testPeaksEvery100msGiveASteadyLine() {
        var line = LevelLine()
        for n in stride(from: 0, to: 80, by: 2) { line.add(peak: 0.1, at: time(n)) }   // 4 s

        let deviations = line.points(at: time(80)).map { abs($0.y - mid) }
        XCTAssertGreaterThan(deviations.min() ?? 0, 0)
        XCTAssertEqual(deviations.min() ?? 0, deviations.max() ?? 0, accuracy: 1e-4, "\(deviations)")
    }

    /// Ruling T17-1: a new recording holds nothing over from the last one. Its
    /// line is flat until its first peak arrives.
    func testResetHoldsNothingUntilTheNextPeak() {
        var line = fed(0.5, through: 0..<20)
        line.reset()

        XCTAssertEqual(deviation(line.points(at: time(30))), 0)
        line.add(peak: 0.1, at: time(30))
        XCTAssertGreaterThan(deviation(line.points(at: time(32))), 0)
    }

    /// Two peaks in one interval: its vertex is the louder, not the later.
    func testAnIntervalKeepsItsLoudestPeak() {
        var line = LevelLine()
        line.add(peak: 0.1, at: time(0) - 0.02)
        line.add(peak: 0.02, at: time(0) + 0.02)

        XCTAssertEqual(line.points(at: time(1)), fed(0.1, through: 0..<1).points(at: time(1)))
    }

    // MARK: - Task 24A: slices timed by when they were captured

    /// The recorder cuts each buffer into slices one interval long, so each
    /// vertex has a peak of its own. It cannot see this type (the library it
    /// lives in comes first), so it keeps the length itself, pinned here.
    func testTheRecorderSlicesAtTheLinesInterval() {
        XCTAssertEqual(AudioRecorder.levelSlice, LevelLine.interval)
    }

    /// Buffers loud for their first 50 ms and quiet for the rest give
    /// alternating loud and quiet slices, and so a different height on each
    /// vertex: no plateau where one buffer's peak stood for two vertices.
    func testSlicedPeaksLeaveNoPlateaus() {
        var line = LevelLine()
        for n in 0..<20 {   // 2 s of 100 ms buffers: sound across the whole line
            feed(slices(of: buffer(first: 0.1, second: 0.02), from: time(2 * n)), to: &line)
        }

        let heights = line.points(at: time(40)).map { abs($0.y - mid) }
        XCTAssertTrue(heights.allSatisfy { $0 > 0 }, "\(heights)")
        for (left, right) in zip(heights, heights.dropFirst()) {
            XCTAssertGreaterThan(abs(left - right), 0.5, "\(heights)")
        }
    }

    /// The recorder hands over a buffer's slices together, 130 ms after the
    /// buffer began, and sometimes two buffers' at once. Each slice keeps the
    /// time it was captured, so what was said keeps its spacing and every
    /// vertex moves left exactly `step` per interval, however the bursts fall:
    /// also while a late buffer is still on its way, which the sweep covers
    /// from buffer 5's arrival on.
    func testBunchedArrivalsStillScrollEvenly() {
        // 100 ms buffers, silent but for two loud slices: the first half of
        // buffer 5 (interval 10) and the second half of buffer 6 (interval 13).
        let buffers = (0..<12).map { n in buffer(first: n == 5 ? 0.1 : 0, second: n == 6 ? 0.1 : 0) }
        // Buffer 6 is late, and comes with buffer 7.
        let arrivals = (0..<12).map { n in time(2 * (n == 6 ? 7 : n)) + 0.13 }

        var line = LevelLine()
        var delivered = 0
        var start: (time: TimeInterval, x: CGFloat)?
        var framesWithBoth = 0
        for frame in stride(from: arrivals[5], to: arrivals[11], by: 0.01) {   // a frame every 10 ms
            while delivered < buffers.count, arrivals[delivered] <= frame {
                feed(slices(of: buffers[delivered], from: time(2 * delivered)), to: &line)
                delivered += 1
            }
            let points = line.points(at: frame)
            // Buffer 5's loud vertex: alone until buffer 6 lands, then the
            // left of the two.
            let bothLoud = delivered > 6
            let x = bothLoud ? twoLoudest(points)[0] : loudest(points).x
            if bothLoud {
                framesWithBoth += 1
                let loud = twoLoudest(points)
                XCTAssertEqual(loud[1] - loud[0], 3 * LevelLine.step, accuracy: 1e-9, "three intervals apart, at \(frame)")
            }
            guard let start else {
                start = (frame, x)
                continue
            }
            let moved = CGFloat((frame - start.time) / LevelLine.interval) * LevelLine.step
            XCTAssertEqual(x, start.x - moved, accuracy: 1e-9, "at \(frame)")
        }
        XCTAssertEqual(delivered, 11, "bursts landed between the frames")
        XCTAssertGreaterThan(framesWithBoth, 0, "the sweep reached buffer 6's arrival")
    }

    // MARK: - Helpers

    /// Halfway through interval `n`, clear of its boundaries.
    private func time(_ n: Int) -> TimeInterval {
        (Double(n) + 0.5) * LevelLine.interval
    }

    /// A line that heard `peak` once in each of `intervals`.
    private func fed(_ peak: Float, through intervals: Range<Int>, onto line: LevelLine = LevelLine()) -> LevelLine {
        var line = line
        for n in intervals { line.add(peak: peak, at: time(n)) }
        return line
    }

    /// How far the line strays from the centre.
    private func deviation(_ points: [CGPoint]) -> CGFloat {
        points.map { abs($0.y - mid) }.max() ?? 0
    }

    /// How far the vertex entering on the right strays from the centre.
    private func entering(_ line: LevelLine, at time: TimeInterval) -> CGFloat {
        deviation(line.points(at: time).filter { $0.x > LevelLine.width })
    }

    /// The point furthest from the centre.
    private func loudest(_ points: [CGPoint]) -> CGPoint {
        points.max { abs($0.y - mid) < abs($1.y - mid) } ?? CGPoint(x: -1, y: mid)
    }

    /// The x of the two points furthest from the centre, left first.
    private func twoLoudest(_ points: [CGPoint]) -> [CGFloat] {
        points.sorted { abs($0.y - mid) > abs($1.y - mid) }.prefix(2).map { $0.x }.sorted()
    }

    /// A 100 ms buffer at 16 kHz: 50 ms peaking at `first`, then 50 ms
    /// peaking at `second`, the sign alternating as in sound.
    private func buffer(first: Float, second: Float) -> [Float] {
        (0..<1_600).map { i in (i < 800 ? first : second) * (i.isMultiple(of: 2) ? 1 : -1) }
    }

    /// `samples` cut into slices as the recorder cuts each buffer, the first
    /// captured at `start`.
    private func slices(of samples: [Float], from start: TimeInterval) -> [(peak: Float, at: TimeInterval)] {
        samples.withUnsafeBufferPointer { AudioRecorder.slicePeaks($0, sampleRate: AudioClip.sampleRate, startTime: start) }
    }

    /// Gives `line` each slice at its own time, as the app does.
    private func feed(_ slices: [(peak: Float, at: TimeInterval)], to line: inout LevelLine) {
        for slice in slices { line.add(peak: slice.peak, at: slice.at) }
    }
}
