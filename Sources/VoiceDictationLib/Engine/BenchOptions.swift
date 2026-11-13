import Foundation

/// What `vd-bench` was asked for, from its arguments: where its clips come
/// from and where the report goes. Kept here, apart from the tool, so the
/// parsing and the loading are tested.
public struct BenchOptions: Equatable {
    /// Where the clips come from.
    public enum Source: Equatable {
        /// The WAV files in a folder: by default the comparison folder that
        /// Task 2's switch filled. The switch is gone (Task 24); the folder
        /// is left on disk, so the clips in it still count.
        case wavs(URL)
        /// The app's kept recordings, `<uuid>.m4a` in the audio archive
        /// (`--from-archive`).
        case archive(URL)
    }

    /// Why the arguments were not understood.
    public struct ArgumentError: LocalizedError, Equatable {
        public let errorDescription: String?

        init(_ message: String) { errorDescription = message }
    }

    public static let usage = "Usage: vd-bench [dir] [--from-archive] [--output file]"
    public static let defaultOutput = "docs/engine-comparison.md"

    public var source: Source
    public var outputPath: String

    public init(source: Source, outputPath: String) {
        self.source = source
        self.outputPath = outputPath
    }

    /// Reads the arguments, the program's name left out. `support` is the
    /// app's data folder, `~/Library/Application Support/VoiceDictation/`.
    /// A folder given is where the clips are, with the flag or without.
    /// Anything else starting with `--`, and a second folder, are refused.
    public static func parse(_ arguments: [String], support: URL) throws -> BenchOptions {
        var arguments = arguments
        var outputPath = defaultOutput
        if let flag = arguments.firstIndex(of: "--output") {
            guard flag + 1 < arguments.count else { throw ArgumentError("--output needs a file path.") }
            outputPath = arguments[flag + 1]
            arguments.removeSubrange(flag...flag + 1)
        }
        let fromArchive = arguments.contains("--from-archive")
        arguments.removeAll { $0 == "--from-archive" }
        if let unknown = arguments.first(where: { $0.hasPrefix("--") }) {
            throw ArgumentError("Unknown option \(unknown).")
        }
        guard arguments.count <= 1 else { throw ArgumentError("Give one folder at most.") }
        let folder = arguments.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let source: Source = fromArchive
            ? .archive(folder ?? support.appendingPathComponent("audio", isDirectory: true))
            : .wavs(folder ?? support.appendingPathComponent("comparison", isDirectory: true))
        return BenchOptions(source: source, outputPath: outputPath)
    }

    /// The folder the clips are read from.
    public var folder: URL {
        switch source {
        case .wavs(let folder), .archive(let folder): folder
        }
    }

    /// The clip files, by name: the folder's `.wav` files, or the archive's
    /// `.m4a` recordings as `AudioArchive` lists them. Other files are left alone.
    public func clipFiles() -> [URL] {
        switch source {
        case .wavs(let folder):
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension.lowercased() == "wav" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        case .archive(let folder):
            let archive = AudioArchive(directory: folder)
            return archive.fileNames().sorted().map { archive.url(for: $0) }
        }
    }

    /// One clip to compare the models on.
    public struct Clip {
        /// The file's name alone (a kept recording's is `<uuid>.m4a`): what
        /// the report shows, so no folder appears in it.
        public let name: String
        public let clip: AudioClip
    }

    /// Reads each file as a 16 kHz mono clip with `AudioClip(contentsOf:)`,
    /// which opens WAVs and the archive's Apple Lossless `.m4a` alike. A file
    /// that cannot be read is skipped, with the reason.
    public static func loadClips(_ files: [URL]) -> (clips: [Clip], skipped: [(name: String, reason: String)]) {
        var clips: [Clip] = []
        var skipped: [(name: String, reason: String)] = []
        for file in files {
            do {
                clips.append(Clip(name: file.lastPathComponent, clip: try AudioClip(contentsOf: file)))
            } catch {
                skipped.append((file.lastPathComponent, error.localizedDescription))
            }
        }
        return (clips, skipped)
    }
}
