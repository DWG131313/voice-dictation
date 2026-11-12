import Foundation
import Speech
import VoiceDictationLib

// vd-bench [dir] [--output file]
// Runs every ready speech model over the WAV files in `dir` (default: the
// comparison folder the app fills) and writes docs/engine-comparison.md.
// It records nothing, pastes nothing and downloads nothing.

var arguments = Array(CommandLine.arguments.dropFirst())
let fileManager = FileManager.default
let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("VoiceDictation", isDirectory: true)

var outputPath = "docs/engine-comparison.md"
if let flag = arguments.firstIndex(of: "--output") {
    guard flag + 1 < arguments.count else {
        print("Usage: vd-bench [dir] [--output file]\n--output needs a file path.")
        exit(2)
    }
    outputPath = arguments[flag + 1]
    arguments.removeSubrange(flag...flag + 1)
}
let directory = arguments.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? support.appendingPathComponent("comparison", isDirectory: true)

let wavs = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension.lowercased() == "wav" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
guard !wavs.isEmpty else {
    print("No WAV files in \(directory.path). Nothing to compare.")
    exit(1)
}
var clips: [(name: String, clip: AudioClip)] = []
for url in wavs {
    do { clips.append((url.lastPathComponent, try AudioClip(contentsOf: url))) } catch {
        print("Skipping \(url.lastPathComponent): \(error.localizedDescription)")
    }
}

guard !clips.isEmpty else {
    print("No readable WAV file in \(directory.path). Nothing to compare.")
    exit(1)
}

let engines: [any TranscriptionEngine] = [
    AppleSpeechEngine(),
    WhisperKitEngine(root: support.appendingPathComponent("whisperkit", isDirectory: true)),
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
