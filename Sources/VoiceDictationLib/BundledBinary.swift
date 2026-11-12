import Foundation

public struct BundledBinary {
    private static var runnable: [String: Bool] = [:]
    private static let lock = NSLock()

    /// Returns all candidate paths for whisper-cli, in priority order.
    /// Bundled binary first, then Homebrew locations.
    public static func searchPaths() -> [String] {
        var paths: [String] = []

        // 1. Bundled binary next to the executable
        if let execURL = Bundle.main.executableURL {
            let bundledPath = execURL.deletingLastPathComponent()
                .appendingPathComponent("whisper-cli").path
            paths.append(bundledPath)
        }

        // 2. Bundled in Resources (for .app bundles)
        if let resourcePath = Bundle.main.resourcePath {
            paths.append(resourcePath + "/whisper-cli")
        }

        // 3. Homebrew (Apple Silicon)
        paths.append("/opt/homebrew/bin/whisper-cli")
        // 4. Homebrew (Intel)
        paths.append("/usr/local/bin/whisper-cli")
        // 5. Legacy names
        paths.append("/opt/homebrew/bin/whisper-cpp")
        paths.append("/usr/local/bin/whisper-cpp")

        return paths
    }

    /// Find the first whisper-cli binary that exists AND actually runs.
    ///
    /// Existing and executable is not enough: an unsigned or badly re-linked
    /// copy is killed by macOS the instant it launches (exit status 9), and a
    /// bundled copy in that state used to shadow a perfectly good Homebrew
    /// install. Each candidate is launched once with `--help` and the verdict
    /// cached for the life of the process.
    public static func findWhisperCLI() -> String? {
        for path in searchPaths() where FileManager.default.isExecutableFile(atPath: path) {
            if canRun(path) { return path }
        }
        return nil
    }

    public static func canRun(_ path: String) -> Bool {
        lock.lock()
        if let cached = runnable[path] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--help"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        var ok = false
        do {
            try process.run()
            process.waitUntilExit()
            ok = process.terminationReason == .exit && process.terminationStatus == 0
        } catch {
            ok = false
        }
        if !ok {
            Log.info("[BINARY] Skipping \(path): it cannot run (reason=\(process.terminationReason.rawValue) status=\(process.terminationStatus)). Unsigned or damaged copy?")
        }

        lock.lock()
        runnable[path] = ok
        lock.unlock()
        return ok
    }
}
