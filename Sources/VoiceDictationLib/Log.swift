import Foundation

/// Lightweight app-wide logger.
///
/// Writes to stdout and to `~/Library/Logs/VoiceDictation.log`, the standard
/// place for per-user app logs (visible in Console.app, survives reboots —
/// unlike the temp directory, which macOS periodically wipes). The file is
/// capped so it can never grow without bound: once it passes `maxBytes` it is
/// rotated to `VoiceDictation.log.old`.
public enum Log {
    public static let fileURL: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("VoiceDictation.log")
    }()

    private static let maxBytes: UInt64 = 1_000_000
    private static let queue = DispatchQueue(label: "VoiceDictation.Log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)"
        print(line)
        queue.async { append(line + "\n") }
    }

    private static func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let fm = FileManager.default
        let path = fileURL.path

        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64, size > maxBytes {
            let old = fileURL.deletingPathExtension().appendingPathExtension("log.old")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: fileURL, to: old)
        }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: fileURL)
        }
    }
}
