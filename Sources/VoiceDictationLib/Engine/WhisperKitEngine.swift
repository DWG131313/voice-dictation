import Foundation
import WhisperKit

/// Argmax's WhisperKit behind `TranscriptionEngine`: OpenAI's Whisper models,
/// converted to Core ML, run in this process. Models and their tokenizers are
/// downloaded into `root` and nowhere else, and once a model is downloaded,
/// loading and running it never touches the network.
public actor WhisperKitEngine: TranscriptionEngine {
    public nonisolated let kind = EngineKind.whisperKit

    /// Builds a loaded pipeline from a load configuration. Tests pass a fake.
    typealias Loader = @Sendable (WhisperKitConfig) async throws -> WhisperKit
    /// Puts a model and its tokenizer under a root. Tests pass a fake.
    typealias Fetcher = @Sendable (Model, URL, @escaping @Sendable (Double) -> Void) async throws -> Void

    private let root: URL
    private let loader: Loader
    private let fetcher: Fetcher
    /// Every model loaded since the last `unload()`. Preparing one model never
    /// evicts another (Ruling T7-3).
    private var loaded: [ModelID: WhisperKit] = [:]
    /// Loads in flight, shared by everyone waiting for the same model. A load
    /// always runs to its end, and `delete` is refused until then; once
    /// `unload()` has given up on it, its pipeline is thrown away unless the
    /// model is asked for again first.
    private var loading: [ModelID: (task: Task<Void, Error>, wanted: Bool)] = [:]
    /// Downloads in flight and how far each has got.
    private var downloads: [ModelID: DownloadProgress] = [:]

    /// `root` holds every model and tokenizer; the app passes
    /// `~/Library/Application Support/VoiceDictation/whisperkit/`.
    public init(root: URL) {
        self.init(root: root) { try await WhisperKit($0) }
    }

    init(root: URL, loader: @escaping Loader) {
        self.init(root: root, loader: loader) { try await Self.fetch($0, into: $1, progress: $2) }
    }

    init(root: URL, loader: @escaping Loader, fetcher: @escaping Fetcher) {
        self.root = root
        self.loader = loader
        self.fetcher = fetcher
    }

    /// The models loaded now.
    var loadedModels: Set<ModelID> { Set(loaded.keys) }

    public func models() async -> [ModelDescriptor] {
        Self.all.map { model in
            let downloaded = isDownloaded(model)
            return ModelDescriptor(
                id: model.id, displayName: model.plainName, detail: model.detail, technicalName: model.technicalName,
                state: state(of: model, downloaded: downloaded),
                bytesOnDisk: downloaded ? Self.size(of: Self.modelFolder(of: model, root: root)) : nil
            )
        }
    }

    /// Loads the model and keeps it, alongside any other loaded model, until
    /// `unload()`. Core ML compiles a model for this Mac the first time it
    /// loads, and again after a macOS update or long disuse (5 s for tiny.en
    /// on an M2, longer for bigger models); `models()` shows `.preparing`
    /// throughout. Throws `modelNotReady` unless the model is downloaded.
    public func prepare(_ id: ModelID) async throws {
        _ = try await pipeline(for: try Self.model(id))
    }

    /// Loads the model first if need be, shown as `.preparing` as in `prepare`.
    public func transcribe(_ clip: AudioClip, model id: ModelID, vocabulary: [String]) async throws -> String {
        try Task.checkCancellation()
        let model = try Self.model(id)
        guard !clip.samples.isEmpty else { return "" }
        let pipeline = try await pipeline(for: model)
        do {
            let options = Self.decodingOptions(vocabulary: vocabulary, tokenizer: pipeline.tokenizer)
            // Clips over one 30 s window are split at a silence, as WhisperKit's
            // `.vad` strategy does, but a chunk that fails is reported here
            // instead of being left out of the text.
            let window = pipeline.featureExtractor.windowSamples ?? Constants.defaultWindowSamples
            let chunks = try await Self.chunks(of: clip.samples, window: window)
            let results = await pipeline.transcribeWithOptions(
                audioArrays: chunks,
                decodeOptionsArray: Array(repeating: options, count: chunks.count)
            )
            // A cancelled chunk comes back as a failed result, not a throw.
            try Task.checkCancellation()
            return try results.flatMap { try $0.get() }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw TranscriptionError.failed("\(model.technicalName) failed: \(error.localizedDescription)")
        }
    }

    /// Fetches the model's folder from Argmax's repository, then its
    /// tokenizer, into `root`. A download that fails or is cancelled leaves
    /// nothing behind.
    public func download(_ id: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        let model = try Self.model(id)
        if isDownloaded(model) {
            progress(1)
            return
        }
        guard downloads[id] == nil else {
            throw TranscriptionError.failed("\(model.technicalName) is already downloading")
        }
        let latest = DownloadProgress()
        downloads[id] = latest
        defer { downloads[id] = nil }
        do {
            try await fetcher(model, root) { fraction in
                latest.fraction = fraction
                progress(fraction)
            }
        } catch {
            do {
                try Self.removeFiles(of: model, root: root)
            } catch let cleanup {
                Log.info("[WHISPERKIT] Could not remove the partial download of \(model.technicalName): \(cleanup.localizedDescription)")
            }
            if Task.isCancelled { throw CancellationError() }
            throw TranscriptionError.failed("\(model.technicalName) could not be downloaded: \(error.localizedDescription)")
        }
        progress(1)
    }

    /// Unloads the model and removes everything `download` wrote for it.
    /// Refused while the model downloads or loads: a load that finds its
    /// tokenizer gone fetches it from the network.
    public func delete(_ id: ModelID) async throws {
        let model = try Self.model(id)
        guard downloads[id] == nil else {
            throw TranscriptionError.failed("\(model.technicalName) is still downloading")
        }
        guard loading[id] == nil else {
            throw TranscriptionError.failed("\(model.technicalName) is still preparing")
        }
        loaded[id] = nil
        do {
            try Self.removeFiles(of: model, root: root)
        } catch {
            throw TranscriptionError.failed("\(model.technicalName) could not be deleted: \(error.localizedDescription)")
        }
    }

    /// Releases every loaded model. A load still in flight runs to its end,
    /// but its model is not kept unless it is asked for again first.
    public func unload() async {
        loaded.removeAll()
        loading = loading.mapValues { (task: $0.task, wanted: false) }
    }

    /// How `prepare` loads a model: from its folder under `root`, with its
    /// tokenizer from `root`, never downloading. Left to its defaults,
    /// WhisperKit would fetch a remote config, download the tokenizer on first
    /// load, and keep both in `~/Documents/huggingface`.
    public static func loadConfig(for model: ModelID, root: URL) -> WhisperKitConfig {
        let folder = all.first { $0.id == model }?.folder ?? model.name
        return WhisperKitConfig(
            model: folder,
            downloadBase: root,
            modelRepo: repo,
            modelFolder: repoFolder(repo, root: root).appending(path: folder, directoryHint: .isDirectory).path,
            tokenizerFolder: root,
            verbose: false,
            load: true,
            download: false
        )
    }

    // MARK: - Loading

    /// The model's pipeline, loading it first if need be. A load in flight
    /// is joined, not repeated, even one that `unload()` gave up on.
    private func pipeline(for model: Model) async throws -> WhisperKit {
        if let pipeline = loaded[model.id] { return pipeline }
        try Task.checkCancellation()
        let load: Task<Void, Error>
        if let running = loading[model.id] {
            loading[model.id]?.wanted = true
            load = running.task
        } else {
            load = try startLoading(model)
        }
        // A cancelled caller stops waiting at once; the load goes on for
        // whoever needs it next.
        try await valueUnlessCancelled(of: load)
        // The load may have ended before this caller was cancelled; a cancelled
        // caller ends in CancellationError, not in "unloaded".
        try Task.checkCancellation()
        guard let pipeline = loaded[model.id] else {
            throw TranscriptionError.modelNotReady("\(model.technicalName) was unloaded before it finished loading")
        }
        return pipeline
    }

    /// Starts loading a downloaded model in a task of its own, so a caller
    /// can stop waiting without stopping the load.
    private func startLoading(_ model: Model) throws -> Task<Void, Error> {
        // `fetch` writes the tokenizer before it can be cancelled, so a model
        // can look downloaded while its download may still remove its files.
        guard downloads[model.id] == nil else {
            throw TranscriptionError.stillDownloading(model.technicalName)
        }
        guard isDownloaded(model) else {
            throw TranscriptionError.modelNotReady("\(model.technicalName) is not downloaded")
        }
        let id = model.id
        let config = Self.loadConfig(for: id, root: root)
        // The entry stays this load's until it ends: `unload()` only marks it
        // unwanted, and `delete` is refused while it is there.
        let task = Task {
            defer { self.loading[id] = nil }
            let pipeline: WhisperKit
            do {
                pipeline = try await self.loader(config)
            } catch {
                throw TranscriptionError.modelNotReady("\(model.technicalName) could not load: \(error.localizedDescription)")
            }
            if self.loading[id]?.wanted == true { self.loaded[id] = pipeline }
        }
        loading[id] = (task, true)
        return task
    }

    // MARK: - Transcribing

    /// The clip in windows of at most `window` samples, split at silences as
    /// WhisperKit's `.vad` strategy splits it. With its default padding the
    /// chunker drops whatever follows the last split when that is 1 s or
    /// less, so the engine keeps such a tail unless it holds no voice: a
    /// silent one would decode to "you".
    static func chunks(of samples: [Float], window: Int) async throws -> [[Float]] {
        var chunks = try await VADAudioChunker(windowPadding: 0)
            .chunkAll(audioArray: samples, maxChunkLength: window, decodeOptions: nil)
            .map(\.audioSamples)
        if chunks.count > 1, let tail = chunks.last, tail.count <= Int(AudioClip.sampleRate), !holdsVoice(tail) {
            chunks.removeLast()
        }
        return chunks
    }

    /// Whether the audio reaches the app's silence floor and EnergyVAD finds
    /// voice in it.
    private static func holdsVoice(_ samples: [Float]) -> Bool {
        AudioClip(samples: samples).peak >= AudioRecorder.silenceThreshold
            && EnergyVAD().voiceActivity(in: samples).contains(true)
    }

    /// English, no timestamps, and the vocabulary as the decoding prompt,
    /// joined as whisper-cli's `--prompt` joins it. `windowClipTime` is 0
    /// because WhisperKit decodes a window only while more than that much
    /// audio is left: its default 1 s turns a 0.65 s "Yes." into "".
    private static func decodingOptions(vocabulary: [String], tokenizer: (any WhisperTokenizer)?) -> DecodingOptions {
        var options = DecodingOptions(
            task: .transcribe, language: "en", usePrefillPrompt: true, detectLanguage: false,
            skipSpecialTokens: true, withoutTimestamps: true, windowClipTime: 0
        )
        if !vocabulary.isEmpty, let tokenizer {
            let prompt = " " + vocabulary.joined(separator: ", ").trimmingCharacters(in: .whitespaces)
            options.promptTokens = tokenizer.encode(text: prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        return options
    }

    // MARK: - Files

    /// Static, so it runs off the actor. WhisperKit's code runs on its caller's
    /// executor, and its Hub client does file work between network reads that
    /// would otherwise hold up `models()` and transcriptions.
    private static func fetch(_ model: Model, into root: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await WhisperKit.download(variant: model.folder, downloadBase: root, from: repo) { files in
            // The tokenizer comes next, so 1 waits until it is in.
            progress(min(files.fractionCompleted, 0.99))
        }
        _ = try await ModelUtilities.loadTokenizer(for: model.variant, tokenizerFolder: root)
        try Task.checkCancellation()
    }

    /// Downloaded means the three Core ML models and the two tokenizer files
    /// WhisperKit needs to load offline are all there. `download` fetches the
    /// tokenizer last and removes everything if any step fails.
    private func isDownloaded(_ model: Model) -> Bool {
        let folder = Self.modelFolder(of: model, root: root)
        let tokenizer = Self.tokenizerFolder(of: model, root: root)
        return ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy {
            FileManager.default.fileExists(atPath: ModelUtilities.detectModelURL(inFolder: folder, named: $0).path)
        } && ["tokenizer.json", "tokenizer_config.json"].allSatisfy {
            FileManager.default.fileExists(atPath: tokenizer.appending(path: $0).path)
        }
    }

    private func state(of model: Model, downloaded: Bool) -> ModelDescriptor.State {
        if let download = downloads[model.id] { return .downloading(download.fraction) }
        if loading[model.id] != nil { return .preparing }
        return (loaded[model.id] != nil || downloaded) ? .ready : .notDownloaded
    }

    /// Removes a model's folder, the Hub client's records and partial files
    /// for it, and its tokenizer. Ones already gone are fine.
    private static func removeFiles(of model: Model, root: URL) throws {
        let folders = [modelFolder(of: model, root: root), downloadRecords(of: model, root: root),
                       tokenizerFolder(of: model, root: root)]
        for folder in folders where FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    /// Bytes the folder takes on disk.
    private static func size(of folder: URL) -> Int64 {
        let key = URLResourceKey.totalFileAllocatedSizeKey
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [key])?.allObjects as? [URL] ?? []
        return files.reduce(0) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [key]))?.totalFileAllocatedSize ?? 0)
        }
    }

    /// Where WhisperKit's Hub client keeps a repository it downloads into
    /// `root`, as `HubApi.localRepoLocation` lays it out.
    private static func repoFolder(_ repo: String, root: URL) -> URL {
        root.appending(path: "models/\(repo)", directoryHint: .isDirectory)
    }

    static func modelFolder(of model: Model, root: URL) -> URL {
        repoFolder(repo, root: root).appending(path: model.folder, directoryHint: .isDirectory)
    }

    /// The Hub client's notes and partial downloads for a model's folder.
    static func downloadRecords(of model: Model, root: URL) -> URL {
        repoFolder(repo, root: root)
            .appending(path: ".cache/huggingface/download/\(model.folder)", directoryHint: .isDirectory)
    }

    static func tokenizerFolder(of model: Model, root: URL) -> URL {
        repoFolder(model.tokenizer, root: root)
    }

    /// The latest fraction a download reported, written from WhisperKit's
    /// progress callback and read by `models()`.
    private final class DownloadProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: Double = 0

        var fraction: Double {
            get { lock.withLock { latest } }
            set { lock.withLock { latest = newValue } }
        }
    }

    // MARK: - The four models

    /// A model this engine offers: its `ModelID` name, its folder on Argmax's
    /// Hugging Face repository, and the tokenizer it needs.
    struct Model {
        let name: String
        let folder: String
        let variant: ModelVariant
        /// The repository WhisperKit takes this variant's tokenizer from
        /// (`ModelUtilities.tokenizerNameForVariant`, internal to WhisperKit).
        let tokenizer: String
        /// The name a person sees: the speed ladder's for large-v3-turbo, the
        /// engine's short name for the three listed only for comparing.
        let plainName: String
        /// The engine's own name, for the Models page, errors and the log.
        let technicalName: String
        let detail: String

        var id: ModelID { ModelID(engine: .whisperKit, name: name) }
    }

    /// Argmax's Core ML conversions of OpenAI's Whisper models.
    private static let repo = "argmaxinc/whisperkit-coreml"

    private static let all: [Model] = [
        Model(name: "tiny.en", folder: "openai_whisper-tiny.en", variant: .tinyEn,
              tokenizer: "openai/whisper-tiny.en", plainName: "WhisperKit tiny", technicalName: "WhisperKit tiny.en",
              detail: "153 MB download — fastest, lower accuracy"),
        Model(name: "base.en", folder: "openai_whisper-base.en", variant: .baseEn,
              tokenizer: "openai/whisper-base.en", plainName: "WhisperKit base", technicalName: "WhisperKit base.en",
              detail: "147 MB download — good balance"),
        Model(name: "small.en", folder: "openai_whisper-small.en", variant: .smallEn,
              tokenizer: "openai/whisper-small.en", plainName: "WhisperKit small", technicalName: "WhisperKit small.en",
              detail: "487 MB download — more accurate, slower"),
        // OpenAI's large-v3-turbo, with 4 decoder layers, and WhisperKit's own
        // default on M2–M4 Macs. Not `openai_whisper-large-v3_turbo`, which
        // despite its name is the full large-v3 with 32.
        Model(name: "large-v3-turbo", folder: "openai_whisper-large-v3-v20240930", variant: .largev3,
              tokenizer: "openai/whisper-large-v3", plainName: "Slowest", technicalName: "WhisperKit large-v3-turbo",
              detail: "1.6 GB download — most accurate, slowest"),
    ]

    static func model(_ id: ModelID) throws -> Model {
        guard let model = all.first(where: { $0.id == id }) else {
            throw TranscriptionError.modelNotReady("Unknown model \(id.storageKey)")
        }
        return model
    }
}
