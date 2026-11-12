import Foundation

/// The value or error of `task`, as `task.value` gives them, except that a
/// caller that is cancelled stops waiting at once and throws
/// `CancellationError` (`task.value` would keep it waiting until the task
/// ends). The task itself is not cancelled: it runs on for whoever waits for
/// it next.
func valueUnlessCancelled<Value: Sendable>(of task: Task<Value, Error>) async throws -> Value {
    let ended = AsyncThrowingStream<Value, Error> { continuation in
        Task {
            continuation.yield(with: await task.result)
            continuation.finish()
        }
    }
    for try await value in ended { return value }
    throw CancellationError()
}
