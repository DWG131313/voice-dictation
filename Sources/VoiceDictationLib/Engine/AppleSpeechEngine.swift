import AVFoundation
import Speech

/// Apple's on-device speech models behind `TranscriptionEngine`. Apple Speech
/// is `SpeechTranscriber`, Apple's newer general-purpose model; Apple
/// Dictation is `DictationTranscriber`, the model behind macOS dictation. Both
/// run in this process on `SpeechAnalyzer`. macOS owns their language files:
/// the engine can ask for them but never deletes them.
public actor AppleSpeechEngine: TranscriptionEngine {
    public nonisolated let kind = EngineKind.appleSpeech

    /// What `prepare` learned about a model, reused for every clip.
    private struct Prepared {
        let locale: Locale
        /// The analyzer's input format (16 kHz 16-bit mono on macOS 27).
        let format: AVAudioFormat
    }

    /// Models stay loaded for the life of the process, so the fresh analyzer
    /// each clip needs starts in a few milliseconds.
    private static let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)

    private var prepared: [ModelID: Prepared] = [:]
    /// Language-file installs in flight, so `models()` can show their progress.
    private var installs: [ModelID: AssetInstallationRequest] = [:]

    public init() {}

    public func models() async -> [ModelDescriptor] {
        var descriptors: [ModelDescriptor] = []
        for model in Self.all {
            descriptors.append(ModelDescriptor(
                id: model, displayName: Self.name(of: model), detail: Self.detail(of: model),
                state: await state(of: model)
            ))
        }
        return descriptors
    }

    /// Throws `engineUnavailable` when this Mac cannot run the model, and
    /// `modelNotReady` unless its language files are installed for this app.
    public func prepare(_ model: ModelID) async throws {
        prepared[model] = nil
        prepared[model] = try await load(model)
    }

    public func transcribe(_ clip: AudioClip, model: ModelID, vocabulary: [String]) async throws -> String {
        do {
            try Task.checkCancellation()
            let setup = try await setUp(model)
            // Loading does not notice a cancel, so look before analysing.
            try Task.checkCancellation()
            let text = try await analyze(clip, model: model, setup: setup, vocabulary: vocabulary)
            try Task.checkCancellation()
            return text
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if error is TranscriptionError { throw error }
            throw TranscriptionError.failed("\(Self.name(of: model)) failed: \(error.localizedDescription)")
        }
    }

    /// Installs the model's language files, or only reserves them for this
    /// app when they are already on the Mac.
    public func download(_ model: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        let locale = try await Self.locale(for: model)
        let module = Self.module(for: model, locale: locale).speechModule
        do {
            // Reserves the locale even when nothing needs downloading, which
            // is when no request comes back.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                installs[model] = request
                // A second download of the same model may have replaced it.
                defer { if installs[model] === request { installs[model] = nil } }
                let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { observed, _ in
                    progress(observed.fractionCompleted)
                }
                defer { observation.invalidate() }
                try await request.downloadAndInstall()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw TranscriptionError.failed(
                "\(Self.name(of: model)) language files could not be installed: \(error.localizedDescription)"
            )
        }
        progress(1)
    }

    public func delete(_ model: ModelID) async throws {
        throw TranscriptionError.failed("Managed by macOS")
    }

    /// Forgets both models and asks macOS to release what `.processLifetime`
    /// kept in memory. The next clip loads its model again.
    public func unload() async {
        prepared.removeAll()
        await SpeechModels.endRetention()
    }

    // MARK: - Preparing

    private func setUp(_ model: ModelID) async throws -> Prepared {
        if let setup = prepared[model] { return setup }
        let setup = try await load(model)
        prepared[model] = setup
        return setup
    }

    /// Checks the model can run here with its language files installed, then
    /// loads it. The analyzer that loads it is thrown away; the model stays.
    private func load(_ model: ModelID) async throws -> Prepared {
        let locale = try await Self.locale(for: model)
        let module = Self.module(for: model, locale: locale).speechModule
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw TranscriptionError.modelNotReady("\(Self.name(of: model)) language files are not installed")
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriptionError.modelNotReady("\(Self.name(of: model)) offered no audio format to analyze")
        }
        do {
            try await SpeechAnalyzer(modules: [module], options: Self.options).prepareToAnalyze(in: format)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw TranscriptionError.modelNotReady("\(Self.name(of: model)) could not load: \(error.localizedDescription)")
        }
        return Prepared(locale: locale, format: format)
    }

    private func state(of model: ModelID) async -> ModelDescriptor.State {
        switch await Self.support(for: model) {
        case .unsupported(let reason):
            return .unavailable(reason)
        case .supported(let locale):
            let module = Self.module(for: model, locale: locale).speechModule
            switch await AssetInventory.status(forModules: [module]) {
            case .installed: return .ready
            case .supported: return .notDownloaded
            case .downloading: return .downloading(installs[model]?.progress.fractionCompleted ?? 0)
            case .unsupported: return .unavailable("Not supported on this Mac")
            @unknown default: return .unavailable("Unknown language file status")
            }
        }
    }

    // MARK: - Transcribing

    /// Runs one clip through a fresh module and analyzer: once an analyzer
    /// finishes it takes no more audio, and its module publishes nothing more.
    private func analyze(_ clip: AudioClip, model: ModelID, setup: Prepared, vocabulary: [String]) async throws -> String {
        // No audio, no text. An unprepared analyzer fed nothing never ends
        // its results (macOS 27.2), so an empty clip never reaches one.
        guard !clip.samples.isEmpty else { return "" }
        let module = Self.module(for: model, locale: setup.locale)
        let analyzer = SpeechAnalyzer(modules: [module.speechModule], options: Self.options)
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        // A few milliseconds once the model is loaded (70 ms or more for
        // Apple Dictation with a vocabulary), and the analyzer knows its input
        // format before the audio arrives. It does not notice a cancel either.
        try await analyzer.prepareToAnalyze(in: setup.format)
        try Task.checkCancellation()
        let (input, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        feed.yield(AnalyzerInput(buffer: try Self.buffer(from: clip, in: setup.format)))
        feed.finish()

        return try await withTaskCancellationHandler {
            let text = Task { try await module.text() }
            do {
                _ = try await analyzer.analyzeSequence(input)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                // Only a finish that ran to the end is sure to have ended the
                // results. A cancel that beat the analysis is not waited on.
                try Task.checkCancellation()
            } catch {
                text.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
            return try await text.value.trimmingCharacters(in: .whitespacesAndNewlines)
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// The clip as one buffer in the analyzer's format.
    private static func buffer(from clip: AudioClip, in format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let source = AudioClip.audioFormat
        let outputFrames = (Double(clip.samples.count) * format.sampleRate / source.sampleRate).rounded(.up)
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(clip.samples.count)),
              let channel = input.floatChannelData?[0],
              let converter = AVAudioConverter(from: source, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(outputFrames)) else {
            throw AudioClipFileError.conversionFailed
        }
        input.frameLength = input.frameCapacity
        clip.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }

        var given = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !given else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? AudioClipFileError.conversionFailed }
        return output
    }

    // MARK: - The two models

    private static let all: [ModelID] = [.appleSpeech, .appleDictation]

    private static func name(of model: ModelID) -> String {
        model == .appleDictation ? "Apple Dictation" : "Apple Speech"
    }

    private static func detail(of model: ModelID) -> String {
        model == .appleDictation
            ? "The model behind macOS dictation, managed by macOS"
            : "Apple's newer general-purpose model, managed by macOS"
    }

    /// A new transcriber. Apple Dictation adds punctuation, which Apple
    /// Speech's `.transcription` preset already includes.
    private static func module(for model: ModelID, locale: Locale) -> Module {
        if model == .appleDictation {
            return .dictation(DictationTranscriber(
                locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                reportingOptions: [], attributeOptions: []
            ))
        }
        return .speech(SpeechTranscriber(locale: locale, preset: .transcription))
    }

    /// Whether this Mac can run a model for en-US, and in which locale.
    private enum Support {
        case supported(Locale)
        case unsupported(String)
    }

    private static func support(for model: ModelID) async -> Support {
        if model == .appleSpeech, !SpeechTranscriber.isAvailable {
            return .unsupported("Not supported on this Mac")
        }
        let english = Locale(identifier: "en-US")
        let locale: Locale?
        if model == .appleDictation {
            locale = await DictationTranscriber.supportedLocale(equivalentTo: english)
        } else {
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: english)
        }
        guard let locale else { return .unsupported("English (US) is not supported") }
        return .supported(locale)
    }

    /// The model's en-US locale, or why it cannot run here.
    private static func locale(for model: ModelID) async throws -> Locale {
        guard all.contains(model) else {
            throw TranscriptionError.modelNotReady("Unknown model \(model.storageKey)")
        }
        switch await support(for: model) {
        case .supported(let locale): return locale
        case .unsupported(let reason): throw TranscriptionError.engineUnavailable("\(name(of: model)): \(reason)")
        }
    }

    /// One of the two transcribers. Their results share a shape but no
    /// protocol for `text`, so each case reads its own.
    private enum Module {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var speechModule: any SpeechModule {
            switch self {
            case .speech(let transcriber): transcriber
            case .dictation(let transcriber): transcriber
            }
        }

        /// Every phrase in order, joined. Returns once the analyzer finishes.
        func text() async throws -> String {
            var phrases: [String] = []
            switch self {
            case .speech(let transcriber):
                for try await result in transcriber.results { phrases.append(String(result.text.characters)) }
            case .dictation(let transcriber):
                for try await result in transcriber.results { phrases.append(String(result.text.characters)) }
            }
            return AppleSpeechEngine.joinPhrases(phrases)
        }
    }

    /// Joins phrases so that one space separates two that meet without
    /// whitespace, and none is added next to whitespace a phrase brings.
    static func joinPhrases(_ phrases: [String]) -> String {
        phrases.reduce(into: "") { text, phrase in
            if let end = text.last, let start = phrase.first, !end.isWhitespace, !start.isWhitespace {
                text += " "
            }
            text += phrase
        }
    }
}
