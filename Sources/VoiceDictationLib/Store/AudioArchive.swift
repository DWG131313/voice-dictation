import Foundation

/// The kept recordings: one Apple Lossless `<uuid>.m4a` per dictation in a
/// folder of its own (`audio/` next to the transcript store). Holds no state
/// beyond the folder; `TranscriptStore` decides which files to keep.
public struct AudioArchive: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Writes `clip` as `<id>.m4a`, creating the folder if needed, and
    /// returns the file name.
    public func save(_ clip: AudioClip, id: UUID) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = id.uuidString + ".m4a"
        try clip.writeALAC(to: url(for: fileName))
        return fileName
    }

    /// Reads a kept recording back as a 16 kHz mono clip.
    public func load(_ fileName: String) throws -> AudioClip {
        try AudioClip(contentsOf: url(for: fileName))
    }

    /// Where `fileName` is (or would be) kept. A name that is not a plain
    /// `<name>.m4a` has no place in the folder: it gets a path where no file
    /// is ever kept, so reading it fails and nothing outside the folder is
    /// reached.
    public func url(for fileName: String) -> URL {
        validURL(for: fileName) ?? directory.appendingPathComponent("invalid-name", isDirectory: false)
    }

    /// The file for `fileName`, or nil unless it is a plain `<name>.m4a`:
    /// not empty, no path separator, not `.` or `..`.
    func validURL(for fileName: String) -> URL? {
        guard !fileName.isEmpty, fileName != ".", fileName != "..", !fileName.contains("/"),
              (fileName as NSString).pathExtension.lowercased() == "m4a" else { return nil }
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Deletes a kept recording. A file that is not there is not an error.
    public func remove(_ fileName: String) {
        guard let file = validURL(for: fileName), FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            Log.info("[AUDIO] Could not remove \(fileName): \(error)")
        }
    }

    /// The names of the `.m4a` files in the folder. Other files and folders
    /// are not the archive's and are not listed.
    func fileNames() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return urls.filter { url in
            url.pathExtension.lowercased() == "m4a"
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }.map(\.lastPathComponent)
    }
}
