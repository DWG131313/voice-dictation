import XCTest
@testable import VoiceDictationLib

/// The cleanup's timed wait (Task 21), apart from the pipeline: a cleaner's
/// run, timed, and the wait for it, which ends with its result, at the time
/// limit, or when it is cancelled, and never stops the run itself.
final class CleanerRunTests: XCTestCase {
    private let cleaner = FakeCleaner()

    /// A result in time: the cleaner's text and how long it took, or its error.
    func testAResultInTime() async throws {
        cleaner.reply = { _ in "Ship it." }
        cleaner.delay = 0.05
        let work = Task { try await CleanerRun.run(cleaner, on: "um ship it") }

        let waited = await CleanerRun.wait(for: work, upTo: 2)

        guard case .finished(.success(let run)) = waited else { return XCTFail("waited: \(waited)") }
        XCTAssertEqual(run.text, "Ship it.")
        XCTAssertGreaterThanOrEqual(run.seconds, 0.05)
        XCTAssertLessThan(run.seconds, 1)
        XCTAssertEqual(cleaner.given, ["um ship it"])

        cleaner.error = TranscriptionError.failed("The model refused")
        let failing = Task { try await CleanerRun.run(cleaner, on: "um ship it") }
        let failed = await CleanerRun.wait(for: failing, upTo: 2)
        guard case .finished(.failure(let error)) = failed else { return XCTFail("waited: \(failed)") }
        XCTAssertEqual(error as? TranscriptionError, .failed("The model refused"))
    }

    /// The limit ends the wait, and the run goes on for a late result.
    func testTheLimitEndsTheWaitButNotTheRun() async throws {
        cleaner.reply = { _ in "Ship it." }
        cleaner.delay = 0.6
        let work = Task { try await CleanerRun.run(cleaner, on: "um ship it") }
        let start = ContinuousClock.now

        let waited = await CleanerRun.wait(for: work, upTo: 0.1)

        let waitedFor = Self.seconds(start.duration(to: .now))
        guard case .timedOut = waited else { return XCTFail("waited: \(waited)") }
        XCTAssertGreaterThanOrEqual(waitedFor, 0.1)
        XCTAssertLessThan(waitedFor, 0.5, "the wait outlasted its limit")
        let run = try await work.value
        XCTAssertEqual(run.text, "Ship it.", "the limit stopped the run")
        XCTAssertGreaterThanOrEqual(run.seconds, 0.6)
    }

    /// A cancelled wait ends at once, and the run goes on.
    func testCancellingTheWaitLeavesTheRunGoing() async throws {
        cleaner.reply = { _ in "Ship it." }
        cleaner.isHeld = true
        let work = Task { try await CleanerRun.run(cleaner, on: "um ship it") }
        let wait = Task { await CleanerRun.wait(for: work, upTo: 5) }
        try await waitUntil("the run starts") { cleaner.given.count == 1 }
        let start = ContinuousClock.now

        wait.cancel()
        let waited = await wait.value

        guard case .cancelled = waited else { return XCTFail("waited: \(waited)") }
        XCTAssertLessThan(Self.seconds(start.duration(to: .now)), 0.5, "the cancelled wait kept waiting")
        XCTAssertEqual(cleaner.finishedCount, 0, "the run ended with the wait")
        cleaner.isHeld = false
        let run = try await work.value
        XCTAssertEqual(run.text, "Ship it.", "cancelling the wait stopped the run")
    }

    // MARK: - Helpers

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private struct Timeout: Error {}

    /// Polls every 5 ms until `condition` holds; fails after 2 s instead of hanging.
    private func waitUntil(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Waited 2 s for: \(what)", file: file, line: line)
                throw Timeout()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
