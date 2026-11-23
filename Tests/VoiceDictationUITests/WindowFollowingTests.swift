import ApplicationServices
import XCTest
@testable import VoiceDictationUI

/// How the tab keeps up with the window in front (2026-11-22). macOS reports
/// a dragged window's moves only about 9 times a second, in every app, so the
/// tab jumped along behind it; and an app just launched can be too busy to
/// answer Accessibility, so its first window had no tab.
final class WindowFollowingTests: XCTestCase {
    private let start = CGRect(x: 100, y: 200, width: 800, height: 600)
    private let moved = CGRect(x: 140, y: 230, width: 800, height: 600)
    private let further = CGRect(x: 180, y: 260, width: 800, height: 600)

    // MARK: - Following a moving window every screen frame

    func testAMoveReportStartsFollowingAndEachNewFrameMovesTheTab() {
        var follower = MoveFollower()
        XCTAssertFalse(follower.isFollowing)
        follower.reported(start, at: 0)
        XCTAssertTrue(follower.isFollowing)

        XCTAssertEqual(follower.tick(moved, at: 0.008), .moved(moved))
        XCTAssertEqual(follower.tick(moved, at: 0.016), .still)
        XCTAssertEqual(follower.tick(further, at: 0.025), .moved(further))
    }

    /// It stops a moment after the window stops, so nothing runs all day.
    func testFollowingStopsOnceTheWindowHasBeenStillLongEnough() {
        var follower = MoveFollower()
        follower.reported(start, at: 0)
        XCTAssertEqual(follower.tick(start, at: MoveFollower.stillness - 0.01), .still)
        XCTAssertEqual(follower.tick(start, at: MoveFollower.stillness), .stop)
        XCTAssertFalse(follower.isFollowing)
        XCTAssertEqual(follower.tick(moved, at: MoveFollower.stillness + 0.01), .stop, "no longer following")
    }

    /// Still for longer than macOS's gap between reports, yet the window is
    /// still being dragged: the next report keeps the following going.
    func testStillnessIsLongerThanTheGapBetweenMoveReports() {
        XCTAssertGreaterThan(MoveFollower.stillness, 0.2, "macOS's reports come about 0.12 s apart")
        var follower = MoveFollower()
        follower.reported(start, at: 0)
        XCTAssertEqual(follower.tick(start, at: 0.12), .still)
        follower.reported(start, at: 0.12)
        XCTAssertEqual(follower.tick(start, at: 0.12 + MoveFollower.stillness - 0.01), .still)
    }

    func testAWindowThatCannotBeReadStopsTheFollowing() {
        var follower = MoveFollower()
        follower.reported(start, at: 0)
        XCTAssertEqual(follower.tick(nil, at: 0.008), .stop)
        XCTAssertFalse(follower.isFollowing)
    }

    func testCancellingStopsTheFollowing() {
        var follower = MoveFollower()
        follower.reported(start, at: 0)
        follower.cancel()
        XCTAssertFalse(follower.isFollowing)
        XCTAssertEqual(follower.tick(moved, at: 0.008), .stop)
    }

    // MARK: - Finding the window in the window server's list

    private func entry(pid: pid_t, number: CGWindowID, layer: Int = 0, _ bounds: CGRect) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: number, kCGWindowLayer as String: layer,
         kCGWindowBounds as String: bounds.dictionaryRepresentation]
    }

    func testTheWindowIsFoundByItsAppAndFrame() {
        let list = [entry(pid: 7, number: 11, CGRect(x: 0, y: 0, width: 300, height: 200)),
                    entry(pid: 9, number: 12, start),
                    entry(pid: 7, number: 13, layer: 25, start),
                    entry(pid: 7, number: 14, start)]
        XCTAssertEqual(WindowServerFrame.number(pid: 7, frame: start, in: list), 14)
    }

    /// Accessibility and the window server can differ by a fraction of a point.
    func testAFrameWithinAPointStillMatches() {
        let list = [entry(pid: 7, number: 14, start.offsetBy(dx: 0.5, dy: -0.5))]
        XCTAssertEqual(WindowServerFrame.number(pid: 7, frame: start, in: list), 14)
    }

    /// Two of the app's windows in the same place: following the wrong one
    /// would be worse than following neither, so neither is used.
    func testNoWindowOrTwoMatchingWindowsGiveNone() {
        XCTAssertNil(WindowServerFrame.number(pid: 7, frame: start, in: [entry(pid: 7, number: 14, moved)]))
        XCTAssertNil(WindowServerFrame.number(pid: 7, frame: start,
                                              in: [entry(pid: 7, number: 14, start), entry(pid: 7, number: 15, start)]))
    }

    // MARK: - Following an app that has only just launched

    func testABusyAppIsTriedAgainSeveralTimes() {
        var retry = FollowRetry()
        for _ in 0..<FollowRetry.attempts {
            XCTAssertEqual(retry.failed(.cannotComplete), FollowRetry.delay)
        }
        XCTAssertNil(retry.failed(.cannotComplete), "gives up after \(FollowRetry.attempts) tries")
    }

    func testOtherErrorsAreNotTriedAgain() {
        var retry = FollowRetry()
        XCTAssertNil(retry.failed(.apiDisabled))
        XCTAssertNil(retry.failed(.notImplemented))
    }

    func testFollowingStartsCountingAfreshForTheNextApp() {
        var retry = FollowRetry()
        for _ in 0..<FollowRetry.attempts { _ = retry.failed(.cannotComplete) }
        retry.reset()
        XCTAssertEqual(retry.failed(.cannotComplete), FollowRetry.delay)
    }
}
