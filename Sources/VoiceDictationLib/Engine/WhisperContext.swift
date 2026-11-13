import Foundation
import whisper

/// One whisper.cpp context. A transcription in flight holds its own
/// reference, so `unload()` never frees a context in use: `whisper_free` runs
/// when the last reference goes.
final class WhisperContext: @unchecked Sendable {
    let pointer: OpaquePointer
    /// Held across `whisper_full` and the read of its text, because whisper.cpp
    /// allows one decode at a time per context (a second one crashes the
    /// process). The service keeps its own slot; this makes a direct caller,
    /// such as vd-bench or a test, wait instead. Only blocking dispatch-queue
    /// work takes it, never code that awaits while holding it.
    private let lock = NSLock()

    private init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        whisper_free(pointer)
    }

    /// Opens a model with whisper-cli's context settings, then decodes one
    /// second of silence and throws the text away, so Metal builds its
    /// pipelines here rather than during the first dictation. Blocks; nil
    /// when whisper.cpp cannot open the file.
    static func open(_ file: URL) -> WhisperContext? {
        _ = routeLogs
        let opened = file.withUnsafeFileSystemRepresentation { path in
            path.flatMap { whisper_init_from_file_with_params($0, WhisperCppEngine.contextParams()) }
        }
        guard let pointer = opened else { return nil }
        let context = WhisperContext(pointer: pointer)
        let silence = [Float](repeating: 0, count: Int(AudioClip.sampleRate))
        let result = context.decode(silence, prompt: "", configure: { _ in }, read: { _ in }).code
        if result != 0 {
            Log.info("[WHISPER] Warming up \(file.lastPathComponent) failed (whisper.cpp error \(result))")
        }
        return context
    }

    /// One `whisper_full` with whisper-cli's settings, `configure` adding the
    /// callbacks, then `read` run on the context while the lock is still held,
    /// so the result it reads is this decode's. Blocks until whisper.cpp
    /// returns, and until any decode already running on this context ends.
    func decode<T>(_ samples: [Float], prompt: String, configure: (inout whisper_full_params) -> Void,
                   read: (WhisperContext) -> T) -> (code: Int32, value: T) {
        lock.withLock {
            let code = prompt.withCString { prompt in
                "en".withCString { language in
                    var params = WhisperCppEngine.fullParams(prompt: prompt, language: language)
                    configure(&params)
                    return samples.withUnsafeBufferPointer {
                        whisper_full(pointer, params, $0.baseAddress, Int32($0.count))
                    }
                }
            }
            return (code, read(self))
        }
    }

    /// The last decode's segments as whisper-cli printed them, without
    /// timestamps. Call only from `decode`'s `read`, under the lock.
    /// `whisper_full_get_segment_text` returns each segment's NUL-terminated
    /// bytes, owned by the context (whisper.h).
    func text() -> String {
        Self.join((0..<whisper_full_n_segments(pointer)).map { index in
            guard let bytes = whisper_full_get_segment_text(pointer, index) else { return [] }
            return Array(UnsafeBufferPointer(start: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self),
                                             count: strlen(bytes)))
        })
    }

    /// The segments' bytes joined with nothing between, then decoded once,
    /// so a character split across two segments stays whole, as whisper-cli's
    /// raw output was when the app decoded it. Differs from the old path's
    /// `String(data:encoding:)` only for invalid UTF-8: that gave nil, which
    /// became ""; this turns each invalid byte into U+FFFD.
    static func join(_ segments: [[UInt8]]) -> String {
        String(decoding: segments.flatMap { $0 }, as: UTF8.self)
    }

    /// Sends whisper.cpp's and ggml's log lines nowhere, except errors, which
    /// go to the app's log. Every load logs one error that is dropped too:
    /// the XCFramework is built with Core ML, finds no
    /// `ggml-*-encoder.mlmodelc` beside the model, and uses its own encoder,
    /// as whisper-cli does. Set once per process, before the first load.
    private static let routeLogs: Void = whisper_log_set({ level, text, _ in
        guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
        let line = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.contains("failed to load Core ML model") else { return }
        Log.info("[WHISPER] \(line)")
    }, nil)
}

/// One transcription's decode, and what whisper.cpp's callbacks read: whether
/// its task was cancelled, and its deadline. `cancel()` may come from any
/// thread, before or during `run()`.
final class Decode: @unchecked Sendable {
    enum Outcome: Sendable {
        case finished(String), timedOut, failed(Int32)
    }

    private let context: WhisperContext
    private let samples: [Float]
    private let prompt: String
    private let timeLimit: TimeInterval
    private let lock = NSLock()
    private var cancelled = false
    private var deadline: ContinuousClock.Instant?
    private var timedOut = false

    init(context: WhisperContext, samples: [Float], prompt: String, timeLimit: TimeInterval) {
        self.context = context
        self.samples = samples
        self.prompt = prompt
        self.timeLimit = timeLimit
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    /// Whether whisper.cpp should stop now: the task was cancelled, or the
    /// deadline has passed. A passed deadline counts as a timeout, never as
    /// a cancel.
    func shouldStop() -> Bool {
        lock.withLock {
            if cancelled { return true }
            if !timedOut, let deadline, ContinuousClock.now >= deadline { timedOut = true }
            return timedOut
        }
    }

    /// Decodes on the calling thread. whisper.cpp asks `abort_callback` after
    /// the encoder and after every decoder step, and then returns -6, -8 or -9;
    /// it asks `encoder_begin_callback` before each window, and then returns 0
    /// with the text so far. Either way the caller reads `isCancelled` and
    /// the outcome, not the text.
    func run() -> Outcome {
        // Cancelled before it started: nothing to decode, and the caller
        // throws CancellationError.
        guard !isCancelled else { return .finished("") }
        let input = WhisperCppEngine.whisperInput(samples)
        lock.withLock { deadline = .now + .seconds(timeLimit) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        let (result, text) = context.decode(input, prompt: prompt, configure: { params in
            params.abort_callback = { data in
                Unmanaged<Decode>.fromOpaque(data!).takeUnretainedValue().shouldStop()
            }
            params.abort_callback_user_data = me
            params.encoder_begin_callback = { _, _, data in
                !Unmanaged<Decode>.fromOpaque(data!).takeUnretainedValue().shouldStop()
            }
            params.encoder_begin_callback_user_data = me
        }, read: { $0.text() })
        if lock.withLock({ timedOut }) { return .timedOut }
        guard result == 0 else { return .failed(result) }
        return .finished(text)
    }
}
