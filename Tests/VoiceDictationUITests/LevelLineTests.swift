import XCTest
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
    /// silence lowers it, so it does not flicker.
    func testRisesFasterThanFalls() {
        let steady = fed(0.1, through: 0..<40)
        let rising = fed(0.1, through: 10..<11, onto: fed(0, through: 0..<10))
        let falling = fed(0, through: 40..<41, onto: steady)

        let rise = entering(rising, at: time(11))
        let fall = entering(steady, at: time(40)) - entering(falling, at: time(41))
        XCTAssertGreaterThan(fall, 0)
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

    /// Ruling T17-1: the microphone sends a peak about every 100 ms, so every
    /// other interval hears none. Such an interval holds the latest peak, so a
    /// steady voice draws a steady line instead of dipping on every other vertex.
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
}
