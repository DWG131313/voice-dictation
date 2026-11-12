import Foundation

/// One whisper-cli process, run to completion on the calling thread. Shared by
/// `Transcriber` and `WhisperCLIEngine`. `cancel()` may be called from any
/// thread, before or during `run()`.
final class WhisperRun: @unchecked Sendable {
    enum Outcome {
        case finished(stdout: String, stderr: String, status: Int32)
        case timedOut
        case cancelled
        case launchFailed(Error)
    }

    private let binaryPath: String
    private let arguments: [String]
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    init(binaryPath: String, arguments: [String], timeout: TimeInterval) {
        self.binaryPath = binaryPath
        self.arguments = arguments
        self.timeout = timeout
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let running = process
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }

    /// Blocks until the process exits, times out, fails to launch or is cancelled.
    func run() -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        lock.lock()
        if isCancelled { lock.unlock(); return .cancelled }
        do {
            try process.run()
        } catch {
            lock.unlock()
            return .launchFailed(error)
        }
        self.process = process
        lock.unlock()

        // Timeout handling
        let timedOut = Flag()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if process.isRunning {
                timedOut.set()
                process.terminate()
            }
        }
        timer.resume()

        // Drain both pipes concurrently. Reading them one after the other
        // can deadlock: whisper blocks writing to a full stderr pipe while
        // we block waiting for stdout to close.
        var errData = Data()
        let errGroup = DispatchGroup()
        errGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            errGroup.leave()
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        errGroup.wait()

        process.waitUntilExit()
        timer.cancel()

        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled { return .cancelled }
        if timedOut.value { return .timedOut }
        return .finished(
            stdout: String(data: outputData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            status: process.terminationStatus
        )
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
}
