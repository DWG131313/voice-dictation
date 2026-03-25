import Foundation

public struct BundledBinary {
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

    /// Find the first available whisper-cli binary.
    public static func findWhisperCLI() -> String? {
        for path in searchPaths() {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}
