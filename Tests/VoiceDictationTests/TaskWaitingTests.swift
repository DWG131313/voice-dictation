import XCTest
@testable import VoiceDictationLib

final class TaskWaitingTests: XCTestCase {
    func testGivesTheValueOrTheError() async throws {
        let value = try await valueUnlessCancelled(of: Task<Int, Error> { 42 })
        XCTAssertEqual(value, 42)

        do {
            _ = try await valueUnlessCancelled(of: Task<Int, Error> { throw TranscriptionError.failed("no") })
            XCTFail("returned instead of throwing the task's error")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .failed("no"))
        }
    }

    /// A cancelled caller stops waiting at once, while the task runs on,
    /// not cancelled, for whoever waits for it next.
    func testCancelledCallerStopsWaitingButTheTaskRunsOn() async throws {
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        defer { open.finish() }
        let work = Task<String, Error> {
            for await _ in gate {}
            try Task.checkCancellation()
            return "done"
        }
        let waiting = Task { try await valueUnlessCancelled(of: work) }

        waiting.cancel()

        let ended = XCTestExpectation(description: "the cancelled caller stopped waiting")
        Task {
            _ = await waiting.result
            ended.fulfill()
        }
        guard await XCTWaiter().fulfillment(of: [ended], timeout: 1) == .completed else {
            return XCTFail("the cancelled caller was still waiting 1 s later, with the task still running")
        }
        switch await waiting.result {
        case .success: XCTFail("returned a value while the task was still running")
        case .failure(let error): XCTAssertTrue(error is CancellationError, "threw \(error)")
        }
        open.finish()
        let value = try await valueUnlessCancelled(of: work)
        XCTAssertEqual(value, "done", "the task was cancelled with its caller")
    }
}
