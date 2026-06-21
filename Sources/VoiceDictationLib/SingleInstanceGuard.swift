import Foundation

/// Prevents more than one VoiceDictation process from running at once.
///
/// macOS can launch the app from several places around login: a restored
/// Terminal tab re-running the binary, a registered login item, a manual
/// run. Without a guard, each launch stacks another menu bar icon — which is
/// exactly the "multiple instances on startup" symptom.
///
/// This uses an advisory `flock` on a lock file. The first process to
/// acquire it wins; any later process fails to acquire and exits. The kernel
/// releases the lock automatically when the holding process exits (even on a
/// crash), so there is never a stale lock file to clean up.
public final class SingleInstanceGuard {
    private let lockURL: URL
    private var fileDescriptor: Int32 = -1

    public init(lockURL: URL = SingleInstanceGuard.defaultLockURL) {
        self.lockURL = lockURL
    }

    /// `~/Library/Application Support/VoiceDictation/instance.lock`
    public static var defaultLockURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceDictation", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("instance.lock")
    }

    /// Attempts to become the sole running instance.
    /// - Returns: `true` if the lock was acquired (this is the only instance),
    ///   `false` if another instance already holds it.
    public func tryAcquire() -> Bool {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            // Can't open the lock file for some reason — fail open so the app
            // still runs rather than silently refusing to start.
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            fileDescriptor = fd
            return true
        }
        close(fd)
        return false
    }

    deinit {
        if fileDescriptor >= 0 {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
    }
}
