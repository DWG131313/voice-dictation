import Foundation
import Speech
import VoiceDictationLib

// vd-bench [dir] [--from-archive] [--output file]
// Runs every ready speech model over the clips and writes
// engine-comparison.md in the app's data folder (--output for elsewhere).
// With --from-archive the clips are the app's kept recordings (`<uuid>.m4a` in its audio folder); without it, the WAV
// files in `dir` (default: the comparison folder Task 2's switch filled).
// It records nothing, pastes nothing and downloads nothing.

let fileManager = FileManager.default
let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("VoiceDictation", isDirectory: true)

let options: BenchOptions
do {
    options = try BenchOptions.parse(Array(CommandLine.arguments.dropFirst()), support: support)
} catch {
    print("\(BenchOptions.usage)\n\(error.localizedDescription)")
    exit(2)
}
let outputPath = options.outputPath
// With `~` for the home folder.
let folderName = (options.folder.path as NSString).abbreviatingWithTildeInPath
let kind: String
switch options.source {
case .wavs: kind = "WAV files"
case .archive: kind = "kept recordings"
}

let files = options.clipFiles()
guard !files.isEmpty else {
    print("No \(kind) in \(folderName). Nothing to compare.")
    exit(1)
}
let loaded = BenchOptions.loadClips(files)
for (name, reason) in loaded.skipped {
    print("Skipping \(name): \(reason)")
}
let clips = loaded.clips.map { (name: $0.name, clip: $0.clip) }

guard !clips.isEmpty else {
    print("None of the \(kind) in \(folderName) could be read. Nothing to compare.")
    exit(1)
}

let engines: [any TranscriptionEngine] = [
    AppleSpeechEngine(),
    WhisperKitEngine(root: support.appendingPathComponent("whisperkit", isDirectory: true)),
    WhisperCppEngine(directory: support.appendingPathComponent("models", isDirectory: true)),
    WhisperCLIEngine(),
]

/// Ruling T10-1: macOS reserves Apple's language files per process, so in a
/// fresh process a model that is on this Mac reads "Not downloaded". When en-US
/// is already installed, reserving it returns at once and offline.
func appleFilesInstalled(_ model: ModelID) async -> Bool {
    let installed = model == .appleDictation
        ? await DictationTranscriber.installedLocales
        : await SpeechTranscriber.installedLocales
    return installed.contains { $0.identifier(.bcp47) == "en-US" }
}

func ready(_ descriptor: ModelDescriptor, engine: any TranscriptionEngine) async -> ModelDescriptor.State {
    guard descriptor.state == .notDownloaded, engine.kind == .appleSpeech else { return descriptor.state }
    guard await appleFilesInstalled(descriptor.id) else { return .notDownloaded }
    do { try await engine.download(descriptor.id) { _ in } } catch { return .unavailable(error.localizedDescription) }
    return await engine.models().first { $0.id == descriptor.id }?.state ?? .notDownloaded
}

func describe(_ state: ModelDescriptor.State) -> String {
    switch state {
    case .ready: "ready"
    case .notDownloaded: "model not downloaded on this Mac"
    case .downloading: "still downloading"
    case .preparing: "still preparing"
    case .unavailable(let reason): reason
    }
}

var rows: [BenchReport.Row] = []
var loadSeconds: [String: Double] = [:]
var skipped: [String: String] = [:]

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

for engine in engines {
    for descriptor in await engine.models() {
        let model = descriptor.id, key = model.storageKey
        let state = await ready(descriptor, engine: engine)
        guard state == .ready else {
            skipped[key] = describe(state)
            print("SKIP \(key): \(describe(state))")
            continue
        }
        do {
            let start = ContinuousClock.now
            try await engine.prepare(model)
            // Run once and discard, so the first clip's time excludes warm-up.
            _ = try await engine.transcribe(clips[0].clip, model: model, vocabulary: [])
            loadSeconds[key] = seconds(start.duration(to: .now))
        } catch {
            skipped[key] = "could not load: \(error.localizedDescription)"
            print("SKIP \(key): could not load: \(error.localizedDescription)")
            continue
        }
        print("LOAD \(key): \(String(format: "%.2f", loadSeconds[key] ?? 0)) s (includes one discarded warm-up)")
        for (name, clip) in clips {
            let start = ContinuousClock.now
            do {
                // The app pastes what OutputFilter leaves, so compare that.
                let text = OutputFilter.clean(try await engine.transcribe(clip, model: model, vocabulary: []))
                let elapsed = seconds(start.duration(to: .now))
                print("\(name)  \(key)  \(String(format: "%.2f", elapsed)) s  \(text)")
                rows.append(.init(clip: name, audioSeconds: clip.duration, model: key, text: text, seconds: elapsed))
            } catch {
                print("\(name)  \(key)  FAILED: \(error.localizedDescription)")
                rows.append(.init(clip: name, audioSeconds: clip.duration, model: key, text: "",
                                  seconds: 0, failure: error.localizedDescription))
            }
        }
        await engine.unload()
    }
}

guard !rows.isEmpty else {
    print("No model was ready. Nothing to report.")
    exit(1)
}
let output = URL(fileURLWithPath: outputPath)
try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try BenchReport.markdown(rows: rows, loadSeconds: loadSeconds, skipped: skipped)
    .write(to: output, atomically: true, encoding: .utf8)
print("Wrote \(output.path)")
