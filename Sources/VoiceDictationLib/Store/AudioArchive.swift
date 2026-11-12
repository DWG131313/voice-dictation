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

    /// Where `fileName` is (or would be) kept. Only its last path component
    /// counts, so a name can never reach outside the folder.
    public func url(for fileName: String) -> URL {
        directory.appendingPathComponent((fileName as NSString).lastPathComponent, isDirectory: false)
    }

    /// Deletes a kept recording. A file that is not there is not an error.
    public func remove(_ fileName: String) {
        let file = url(for: fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
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
