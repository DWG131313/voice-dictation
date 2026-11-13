import Foundation

/// What a cleaner gave back for one text, and how long it took. The
/// pipeline starts the cleaner with `run(_:on:)` and waits for it, up to its
/// time limit, with `wait(for:upTo:)`. Neither touches the pipeline.
struct CleanerRun: Sendable {
    let text: String
    let seconds: Double

    /// What the wait for a cleanup saw first.
    enum Waited: Sendable {
        case finished(Result<CleanerRun, Error>)
        case timedOut
        case cancelled
    }

    /// Runs `cleaner` on `raw`, off the main thread, and times it.
    static func run(_ cleaner: TextCleaner, on raw: String) async throws -> CleanerRun {
        let start = ContinuousClock.now
        let text = try await cleaner.clean(raw)
        let elapsed = start.duration(to: .now).components
        return CleanerRun(text: text, seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }

    /// Waits for `work` until it ends, `seconds` pass, or this wait is
    /// cancelled, whichever comes first. `work` itself is never cancelled
    /// here: past the time limit it runs on, for a late result.
    static func wait(for work: Task<CleanerRun, Error>, upTo seconds: TimeInterval) async -> Waited {
        await withTaskGroup(of: Waited.self) { group in
            group.addTask {
                do {
                    return .finished(.success(try await valueUnlessCancelled(of: work)))
                } catch {
                    return Task.isCancelled ? .cancelled : .finished(.failure(error))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(seconds))
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }
    }
}
