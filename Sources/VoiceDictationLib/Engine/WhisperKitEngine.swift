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

    private let root: URL
    private let loader: Loader
    /// Every model loaded since the last `unload()`. Preparing one model never
    /// evicts another (Ruling T7-3).
    private var loaded: [ModelID: WhisperKit] = [:]
    /// Loads in flight, shared by everyone waiting for the same model. The
    /// token lets a load that `unload()` or `delete` dropped end unseen.
    private var loading: [ModelID: (token: UUID, task: Task<Void, Error>)] = [:]
    /// Downloads in flight and how far each has got.
    private var downloads: [ModelID: DownloadProgress] = [:]

    /// `root` holds every model and tokenizer; the app passes
    /// `~/Library/Application Support/VoiceDictation/whisperkit/`.
    public init(root: URL) {
        self.init(root: root) { try await WhisperKit($0) }
    }

    init(root: URL, loader: @escaping Loader) {
        self.root = root
        self.loader = loader
    }

    /// The models loaded now.
    var loadedModels: Set<ModelID> { Set(loaded.keys) }

    public func models() async -> [ModelDescriptor] {
        Self.all.map { model in
            let downloaded = isDownloaded(model)
            return ModelDescriptor(
                id: model.id, displayName: model.displayName, detail: model.detail,
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
        let pipeline = try await pipeline(for: model)
        guard !clip.samples.isEmpty else { return "" }
        do {
            let options = Self.decodingOptions(vocabulary: vocabulary, tokenizer: pipeline.tokenizer)
            // Clips over one 30 s window are split at a silence, as WhisperKit's
            // `.vad` strategy does, but a chunk that fails is reported here
            // instead of being left out of the text.
            let window = pipeline.featureExtractor.windowSamples ?? Constants.defaultWindowSamples
            let chunks = try await VADAudioChunker().chunkAll(
                audioArray: clip.samples, maxChunkLength: window, decodeOptions: options
            )
            let results = await pipeline.transcribeWithOptions(
                audioArrays: chunks.map(\.audioSamples),
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
            throw TranscriptionError.failed("\(model.displayName) failed: \(error.localizedDescription)")
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
            throw TranscriptionError.failed("\(model.displayName) is already downloading")
        }
        let latest = DownloadProgress()
        downloads[id] = latest
        defer { downloads[id] = nil }
        do {
            try await Self.fetch(model, into: root) { fraction in
                latest.fraction = fraction
                progress(fraction)
            }
        } catch {
            try? Self.removeFiles(of: model, root: root)
            if Task.isCancelled { throw CancellationError() }
            throw TranscriptionError.failed("\(model.displayName) could not be downloaded: \(error.localizedDescription)")
        }
        progress(1)
    }

    /// Unloads the model and removes everything `download` wrote for it.
    public func delete(_ id: ModelID) async throws {
        let model = try Self.model(id)
        guard downloads[id] == nil else {
            throw TranscriptionError.failed("\(model.displayName) is still downloading")
        }
        loaded[id] = nil
        loading[id] = nil
        do {
            try Self.removeFiles(of: model, root: root)
        } catch {
            throw TranscriptionError.failed("\(model.displayName) could not be deleted: \(error.localizedDescription)")
        }
    }

    /// Releases every loaded model. A load still in flight is dropped when it ends.
    public func unload() async {
        loaded.removeAll()
        loading.removeAll()
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
    /// is joined, not repeated.
    private func pipeline(for model: Model) async throws -> WhisperKit {
        while true {
            if let pipeline = loaded[model.id] { return pipeline }
            try Task.checkCancellation()
            let load = try loading[model.id]?.task ?? startLoading(model)
            // A load that `unload()` or `delete` dropped ends without storing
            // its pipeline; the next turn loads again or finds the files gone.
            try await Self.wait(for: load)
        }
    }

    /// Starts loading a downloaded model in a task of its own, so a caller
    /// can stop waiting without stopping the load.
    private func startLoading(_ model: Model) throws -> Task<Void, Error> {
        guard isDownloaded(model) else {
            throw TranscriptionError.modelNotReady("\(model.displayName) is not downloaded")
        }
        let id = model.id, token = UUID()
        let config = Self.loadConfig(for: id, root: root)
        let task = Task {
            defer { if self.loading[id]?.token == token { self.loading[id] = nil } }
            let pipeline: WhisperKit
            do {
                pipeline = try await self.loader(config)
            } catch {
                throw TranscriptionError.modelNotReady("\(model.displayName) could not load: \(error.localizedDescription)")
            }
            if self.loading[id]?.token == token { self.loaded[id] = pipeline }
        }
        loading[id] = (token, task)
        return task
    }

    /// Waits for a load to end without being tied to it: a cancelled caller
    /// stops waiting at once, and the load goes on for whoever needs it next.
    private static func wait(for load: Task<Void, Error>) async throws {
        let ended = AsyncThrowingStream<Void, Error> { continuation in
            Task {
                continuation.yield(with: await load.result)
                continuation.finish()
            }
        }
        for try await _ in ended { return }
        throw CancellationError()
    }

    // MARK: - Transcribing

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
        let displayName: String
        let detail: String

        var id: ModelID { ModelID(engine: .whisperKit, name: name) }
    }

    /// Argmax's Core ML conversions of OpenAI's Whisper models.
    private static let repo = "argmaxinc/whisperkit-coreml"

    private static let all: [Model] = [
        Model(name: "tiny.en", folder: "openai_whisper-tiny.en", variant: .tinyEn,
              tokenizer: "openai/whisper-tiny.en", displayName: "WhisperKit tiny.en",
              detail: "153 MB download — fastest, lower accuracy"),
        Model(name: "base.en", folder: "openai_whisper-base.en", variant: .baseEn,
              tokenizer: "openai/whisper-base.en", displayName: "WhisperKit base.en",
              detail: "147 MB download — good balance"),
        Model(name: "small.en", folder: "openai_whisper-small.en", variant: .smallEn,
              tokenizer: "openai/whisper-small.en", displayName: "WhisperKit small.en",
              detail: "487 MB download — more accurate, slower"),
        // OpenAI's large-v3-turbo, with 4 decoder layers, and WhisperKit's own
        // default on M2–M4 Macs. Not `openai_whisper-large-v3_turbo`, which
        // despite its name is the full large-v3 with 32.
        Model(name: "large-v3-turbo", folder: "openai_whisper-large-v3-v20240930", variant: .largev3,
              tokenizer: "openai/whisper-large-v3", displayName: "WhisperKit large-v3-turbo",
              detail: "1.6 GB download — most accurate, slowest"),
    ]

    static func model(_ id: ModelID) throws -> Model {
        guard let model = all.first(where: { $0.id == id }) else {
            throw TranscriptionError.modelNotReady("Unknown model \(id.storageKey)")
        }
        return model
    }
}
