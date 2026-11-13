import CryptoKit
import Foundation

/// Downloads a ggml model from Hugging Face into the models folder, for
/// `WhisperCppEngine.download` (Task 27A). The file arrives as
/// `<fileName>.partial` and takes its own name only once its HTTP status,
/// size and SHA-256 match the catalog, so the engine never sees half a model.
/// The URLs use branch main with no tag checked: the SHA-256 is what keeps
/// the weights the golden tests ran with, since a file changed upstream fails
/// the download instead.
public enum GGMLDownload {
    /// Fetches `model.url` into `directory` as `<fileName>.partial`, reporting 0…1 as bytes arrive. Then it checks
    /// the HTTP status, the size and the SHA-256 against the catalog and renames the file to `<fileName>`. A failure
    /// or a cancellation leaves neither file behind. It never retries: the row shows the failure.
    public static func fetch(_ model: GGMLModel, into directory: URL, session: URLSession = .shared,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        let partial = directory.appendingPathComponent(model.fileName + ".partial")
        let file = directory.appendingPathComponent(model.fileName)
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Left by an earlier download that the app did not live to finish.
            try removeIfPresent(partial)
            try await download(model, to: partial, session: session, progress: progress)
            try await check(partial, against: model)
            try Task.checkCancellation()
            // Only a file of another size can be here: the engine fetches
            // nothing while the model is whole.
            try removeIfPresent(file)
            try FileManager.default.moveItem(at: partial, to: file)
        } catch {
            do {
                try removeIfPresent(partial)
            } catch let cleanup {
                Log.info("[WHISPER] Could not remove the partial download of \(model.displayName): \(cleanup.localizedDescription)")
            }
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if error is TranscriptionError { throw error }
            throw failure(model, error.localizedDescription)
        }
    }

    /// The file's SHA-256 in lowercase hex, read 1 MB at a time.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 1 << 20) }), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// How a failed download reads on the model's row.
    static func failure(_ model: GGMLModel, _ reason: String) -> TranscriptionError {
        .failed("\(model.displayName) could not be downloaded: \(reason)")
    }

    // MARK: - Steps

    /// Runs one download task, which leaves its file at `partial`. A cancel
    /// cancels the task, which then completes with `NSURLErrorCancelled`.
    private static func download(_ model: GGMLModel, to partial: URL, session: URLSession,
                                 progress: @escaping @Sendable (Double) -> Void) async throws {
        let transfer = Transfer(model: model, partial: partial, progress: progress)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                transfer.start(in: session, continuation: continuation)
            }
        } onCancel: {
            transfer.cancel()
        }
    }

    /// The size first, which is cheap, then the SHA-256, hashed on a
    /// dispatch queue rather than a Swift concurrency thread: small.en's
    /// 488 MB take a second or two.
    private static func check(_ partial: URL, against model: GGMLModel) async throws {
        let size = try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64
        guard size == model.bytes else {
            throw failure(model, "it was \(size.map(String.init) ?? "an unknown number of") bytes, not \(model.bytes)")
        }
        let digest = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try sha256(of: partial) })
            }
        }
        guard digest == model.sha256 else { throw failure(model, "its checksum does not match the catalog's") }
    }

    private static func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// One download task and its delegate, set on the task itself. NSURLSession.h:
/// the session calls `urlSession(_:downloadTask:didWriteData:…)` "periodically"
/// with progress; `urlSession(_:downloadTask:didFinishDownloadingTo:)` hands
/// over a file that "will be removed when the delegate message returns", and
/// a server's error page arrives that way too, so the status is read there;
/// `urlSession(_:task:didCompleteWithError:)` "will still be called", with
/// `NSURLErrorCancelled` after `cancel()`. A task's delegate "cannot be
/// modified after task resumes". The callbacks come one at a time, on the
/// session's queue; `start` and `cancel` may come from any thread.
private final class Transfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let model: GGMLModel
    private let partial: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var isCancelled = false
    private var continuation: CheckedContinuation<Void, Error>?
    /// What the finished download came to, before the task completes.
    private var outcome: Result<Void, Error>?

    init(model: GGMLModel, partial: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.model = model
        self.partial = partial
        self.progress = progress
    }

    func start(in session: URLSession, continuation: CheckedContinuation<Void, Error>) {
        let task = session.downloadTask(with: model.url)
        task.delegate = self
        let cancelledFirst = lock.withLock {
            self.task = task
            self.continuation = continuation
            return isCancelled
        }
        task.resume()
        if cancelledFirst { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }

    /// Measured against the catalog's size, which every whole file has, so a
    /// missing Content-Length changes nothing.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(min(1, Double(totalBytesWritten) / Double(max(model.bytes, 1))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let result: Result<Void, Error>
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            result = .failure(GGMLDownload.failure(model, "HTTP \(http.statusCode)"))
        } else {
            result = Result { try FileManager.default.moveItem(at: location, to: partial) }
        }
        lock.withLock { outcome = result }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, outcome) = lock.withLock {
            defer {
                self.continuation = nil
                self.task = nil
            }
            return (self.continuation, self.outcome)
        }
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(with: outcome ?? .failure(GGMLDownload.failure(model, "no file arrived")))
        }
    }
}
