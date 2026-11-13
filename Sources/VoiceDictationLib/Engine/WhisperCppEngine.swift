import Foundation
import whisper

/// whisper.cpp in this process, behind `TranscriptionEngine`: the ggml models
/// whisper-cli used, read from the same folder, decoded with the settings the
/// app ran whisper-cli with, so it gives the text whisper-cli gave (Task 27;
/// the settings are read from v1.9.5's `examples/cli/cli.cpp`). The default
/// engine since Task 27A, which retired whisper-cli and lets this engine
/// download its models (`GGMLDownload`).
///
/// whisper.cpp blocks while it loads and decodes, so both run on a global
/// dispatch queue, never on a Swift concurrency thread. No context is used by
/// two calls at once: a context is published only after its warm-up, the
/// service never runs two transcriptions at once, and a context is freed only
/// when nothing holds it.
public actor WhisperCppEngine: TranscriptionEngine {
    public nonisolated let kind = EngineKind.whisperCpp

    /// Opens a model file and warms it up, blocking; nil when it cannot.
    /// Tests pass a fake.
    typealias Loader = @Sendable (URL) -> WhisperContext?
    /// How long a clip of this many seconds may decode. Tests pass a short one.
    typealias Timeout = @Sendable (TimeInterval) -> TimeInterval
    /// Puts a model's whole, checked file in a folder, reporting progress.
    /// Tests pass a fake.
    typealias Fetcher = @Sendable (GGMLModel, URL, @escaping @Sendable (Double) -> Void) async throws -> Void

    private let directory: URL
    private let loader: Loader
    private let timeout: Timeout
    private let fetcher: Fetcher
    /// Every model loaded since the last `unload()`. Preparing one model never
    /// evicts another.
    private var loaded: [ModelID: WhisperContext] = [:]
    /// Loads in flight, shared by everyone waiting for the same model. A load
    /// always runs to its end, and `delete` is refused until then; once
    /// `unload()` has given up on it, its context is freed unless the model is
    /// asked for again first.
    private var loading: [ModelID: (task: Task<Void, Error>, wanted: Bool)] = [:]
    /// Downloads in flight and how far each has got.
    private var downloads: [ModelID: DownloadProgress] = [:]

    /// `directory` holds the `ggml-*.bin` files; the app and vd-bench pass
    /// `~/Library/Application Support/VoiceDictation/models/`.
    public init(directory: URL) {
        self.init(directory: directory, loader: { WhisperContext.open($0) },
                  timeout: { Self.timeout(recordingDuration: $0) }, fetcher: Self.fetchFromHuggingFace)
    }

    init(directory: URL, loader: @escaping Loader) {
        self.init(directory: directory, loader: loader,
                  timeout: { Self.timeout(recordingDuration: $0) }, fetcher: Self.fetchFromHuggingFace)
    }

    init(directory: URL, timeout: @escaping Timeout) {
        self.init(directory: directory, loader: { WhisperContext.open($0) },
                  timeout: timeout, fetcher: Self.fetchFromHuggingFace)
    }

    init(directory: URL, loader: @escaping Loader = { WhisperContext.open($0) }, fetcher: @escaping Fetcher) {
        self.init(directory: directory, loader: loader,
                  timeout: { Self.timeout(recordingDuration: $0) }, fetcher: fetcher)
    }

    private init(directory: URL, loader: @escaping Loader, timeout: @escaping Timeout, fetcher: @escaping Fetcher) {
        self.directory = directory
        self.loader = loader
        self.timeout = timeout
        self.fetcher = fetcher
    }

    /// The real download, off the actor: `models()` and transcriptions go on
    /// while the bytes arrive.
    private static let fetchFromHuggingFace: Fetcher = { model, directory, progress in
        try await GGMLDownload.fetch(model, into: directory, progress: progress)
    }

    /// The models loaded now.
    var loadedModels: Set<ModelID> { Set(loaded.keys) }

    public func models() async -> [ModelDescriptor] {
        GGMLModel.all.map { model in
            let onDisk = size(of: model)
            let whole = onDisk == model.bytes
            return ModelDescriptor(
                id: model.id, displayName: model.displayName, detail: model.detail,
                state: state(of: model, whole: whole), bytesOnDisk: whole ? onDisk : nil
            )
        }
    }

    /// Loads the model and keeps it, alongside any other loaded model, until
    /// `unload()`, then decodes one second of silence, so Metal builds its
    /// pipelines now rather than during the first dictation. `models()` shows
    /// `.preparing` throughout. Throws `modelNotReady` unless the model's file
    /// is there whole.
    public func prepare(_ id: ModelID) async throws {
        _ = try await context(for: try Self.model(id))
    }

    /// Loads the model first if need be, shown as `.preparing` as in
    /// `prepare`, then decodes the clip as whisper-cli did: one `whisper_full`
    /// on the samples whisper-cli read back from its 16-bit WAV. A decode that
    /// runs past whisper-cli's time limit throws whisper-cli's timeout error.
    public func transcribe(_ clip: AudioClip, model id: ModelID, vocabulary: [String]) async throws -> String {
        try Task.checkCancellation()
        let model = try Self.model(id)
        guard !clip.samples.isEmpty else { return "" }
        let whisper = try await context(for: model)
        let decode = Decode(context: whisper, samples: clip.samples,
                            prompt: Self.prompt(for: vocabulary), timeLimit: timeout(clip.duration))
        let outcome = await withTaskCancellationHandler {
            await Self.offThePool { decode.run() }
        } onCancel: {
            decode.cancel()
        }
        // A cancel stops the decode at whisper.cpp's next check, and the
        // caller gets CancellationError whatever whisper.cpp returned then. A
        // cancel that lands after the decode ended counts too.
        if decode.isCancelled || Task.isCancelled { throw CancellationError() }
        switch outcome {
        case .finished(let text):
            return text
        case .timedOut:
            throw TranscriptionError.failed(Self.timedOut)
        case .failed(let code):
            throw TranscriptionError.failed("\(model.displayName) failed (whisper.cpp error \(code))")
        }
    }

    /// Fetches the model's ggml file into the models folder (`GGMLDownload`),
    /// shown as `.downloading` meanwhile. A model whose file is there whole
    /// returns at once. A failed or cancelled download leaves no file, and
    /// the model reads Not downloaded again.
    public func download(_ id: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        let model = try Self.model(id)
        if size(of: model) == model.bytes {
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
            try await fetcher(model, directory) { fraction in
                latest.fraction = fraction
                progress(fraction)
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            // `GGMLDownload`'s own words already name the model.
            if error is TranscriptionError { throw error }
            throw TranscriptionError.failed("\(model.displayName) could not be downloaded: \(error.localizedDescription)")
        }
        progress(1)
    }

    /// Unloads the model and removes its file. Refused while the model
    /// downloads or loads. The service refuses the model in use before it
    /// gets here.
    public func delete(_ id: ModelID) async throws {
        let model = try Self.model(id)
        guard downloads[id] == nil else {
            throw TranscriptionError.failed("\(model.displayName) is still downloading")
        }
        guard loading[id] == nil else {
            throw TranscriptionError.failed("\(model.displayName) is still preparing")
        }
        loaded[id] = nil
        let url = file(of: model)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw TranscriptionError.failed("\(model.displayName) could not be deleted: \(error.localizedDescription)")
        }
    }

    /// Releases every loaded model. One still transcribing is freed when it
    /// finishes. A load still in flight runs to its end, but its model is not
    /// kept unless it is asked for again first.
    public func unload() async {
        loaded.removeAll()
        loading = loading.mapValues { (task: $0.task, wanted: false) }
    }

    // MARK: - whisper-cli's settings

    /// whisper-cli's context: `whisper_context_default_params()` with the
    /// values cli.cpp passes, GPU on, flash attention on, device 0, no DTW.
    static func contextParams() -> whisper_context_params {
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        params.gpu_device = 0
        params.dtw_token_timestamps = false
        return params
    }

    /// What cli.cpp passes to `whisper_full` for `--no-timestamps --no-prints
    /// --suppress-nst --language en [--prompt …]`. `prompt` and `language`
    /// must outlive the decode. The rest stays at
    /// `whisper_full_default_params(WHISPER_SAMPLING_GREEDY)`, as cli.cpp
    /// leaves it or sets the same values: `no_context` (true), `n_threads`,
    /// `n_max_text_ctx`, and the VAD, which is off.
    static func fullParams(prompt: UnsafePointer<CChar>, language: UnsafePointer<CChar>) -> whisper_full_params {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        // cli.cpp switches to beam search because its beam size, 5, is above 1;
        // the temperature fallback samples with best-of decoders.
        params.strategy = WHISPER_SAMPLING_BEAM_SEARCH
        params.beam_search.beam_size = 5
        params.greedy.best_of = 5
        params.temperature = 0
        params.temperature_inc = 0.2
        params.entropy_thold = 2.4
        params.logprob_thold = -1
        params.no_speech_thold = 0.6
        params.language = language
        params.translate = false
        params.detect_language = false
        params.no_timestamps = true
        params.suppress_nst = true
        // cli.cpp passes an empty string, not null, when there is no prompt.
        params.initial_prompt = prompt
        params.carry_initial_prompt = false
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.token_timestamps = false
        params.max_len = 0
        params.audio_ctx = 0
        params.offset_ms = 0
        params.duration_ms = 0
        return params
    }

    /// The vocabulary as whisper-cli's `--prompt`: joined with ", ", or ""
    /// when there is none.
    static func prompt(for vocabulary: [String]) -> String {
        vocabulary.joined(separator: ", ")
    }

    /// The samples whisper-cli read back from the WAV `AudioClip.writeWAV`
    /// wrote. Core Audio wrote each sample × 32768, rounded to the nearest
    /// integer with halves away from zero, clipped to 16 bits (measured
    /// 2026-11-13); miniaudio read each back × 1/32768 (v1.9.5's
    /// `examples/miniaudio.h`, `ma_dr_wav_s16_to_f32`).
    static func whisperInput(_ samples: [Float]) -> [Float] {
        samples.map { sample in
            let scaled = (sample * 32768).rounded(.toNearestOrAwayFromZero)
            return Float(Int16(max(-32768, min(32767, scaled)))) * (1.0 / 32768)
        }
    }

    /// whisper-cli's time limit, kept when its code went (Task 27A). A
    /// generous floor: the first run after a cold start pays for model
    /// loading and Metal shader compilation.
    static func timeout(recordingDuration: TimeInterval) -> TimeInterval {
        max(20.0, recordingDuration * 3.0)
    }

    /// The words the app has always shown for a timeout, whisper-cli's.
    static let timedOut = "Transcription timed out — try a shorter recording or a smaller model"

    // MARK: - Loading

    /// The model's context, loading it first if need be. A load in flight is
    /// joined, not repeated, even one that `unload()` gave up on.
    private func context(for model: GGMLModel) async throws -> WhisperContext {
        if let context = loaded[model.id] { return context }
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
        try Task.checkCancellation()
        guard let context = loaded[model.id] else {
            throw TranscriptionError.modelNotReady("\(model.displayName) was unloaded before it finished loading")
        }
        return context
    }

    /// Starts loading a model whose file is whole, in a task of its own, so a
    /// caller can stop waiting without stopping the load. The context is
    /// published only once its warm-up has run.
    private func startLoading(_ model: GGMLModel) throws -> Task<Void, Error> {
        // A download may still fail and remove what it wrote, so a load
        // never starts under one.
        guard downloads[model.id] == nil else {
            throw TranscriptionError.modelNotReady("\(model.displayName) is still downloading")
        }
        guard size(of: model) == model.bytes else {
            throw TranscriptionError.modelNotReady("\(model.displayName) is not downloaded")
        }
        let id = model.id
        let url = file(of: model)
        let loader = loader
        // The entry stays this load's until it ends: `unload()` only marks it
        // unwanted, and `delete` is refused while it is there.
        let task = Task {
            defer { self.loading[id] = nil }
            guard let context = await Self.offThePool({ loader(url) }) else {
                throw TranscriptionError.modelNotReady("\(model.displayName) could not load")
            }
            if self.loading[id]?.wanted == true { self.loaded[id] = context }
        }
        loading[id] = (task, true)
        return task
    }

    /// Runs blocking whisper.cpp work on a global dispatch queue, reached
    /// through a continuation, so it never holds a Swift concurrency thread.
    private static func offThePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    // MARK: - Files

    private func state(of model: GGMLModel, whole: Bool) -> ModelDescriptor.State {
        if let download = downloads[model.id] { return .downloading(download.fraction) }
        if loading[model.id] != nil { return .preparing }
        return (loaded[model.id] != nil || whole) ? .ready : .notDownloaded
    }

    private func file(of model: GGMLModel) -> URL {
        directory.appendingPathComponent(model.fileName)
    }

    /// The size of the model's file, or nil when it is not there.
    private func size(of model: GGMLModel) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file(of: model).path)
        return attributes?[.size] as? Int64
    }

    static func model(_ id: ModelID) throws -> GGMLModel {
        guard let model = GGMLModel.all.first(where: { $0.id == id }) else {
            throw TranscriptionError.modelNotReady("Unknown model \(id.storageKey)")
        }
        return model
    }

    /// The latest fraction a download reported, written from the fetcher's
    /// progress callback and read by `models()`.
    private final class DownloadProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: Double = 0

        var fraction: Double {
            get { lock.withLock { latest } }
            set { lock.withLock { latest = newValue } }
        }
    }
}
