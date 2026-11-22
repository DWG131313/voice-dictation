import Foundation

/// The ggml files on Hugging Face (`ggerganov/whisper.cpp`, branch main; sizes
/// and SHA-256 read 2026-11-12). They are the three files whisper-cli used,
/// kept in the same folder, `~/Library/Application Support/VoiceDictation/models/`.
public struct GGMLModel: Sendable, Equatable {
    /// The `ModelID` name, as whisper-cli's models were named.
    public let name: String
    public let fileName: String
    /// The speed ladder's name a person sees (spec 2026-11-22).
    public let plainName: String
    /// whisper-cli's name, kept for the Models page, errors and the log.
    public let technicalName: String
    public let detail: String
    /// The whole file's size; a file of any other size is not this model.
    public let bytes: Int64
    public let sha256: String

    public var url: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    var id: ModelID { ModelID(engine: .whisperCpp, name: name) }

    public static let all: [GGMLModel] = [
        GGMLModel(name: "tiny.en", fileName: "ggml-tiny.en.bin", plainName: "Fastest",
                  technicalName: "whisper.cpp tiny.en",
                  detail: "78 MB download — fastest, lower accuracy", bytes: 77_704_715,
                  sha256: "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f"),
        GGMLModel(name: "base.en", fileName: "ggml-base.en.bin", plainName: "Fast",
                  technicalName: "whisper.cpp base.en",
                  detail: "148 MB download — good balance", bytes: 147_964_211,
                  sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"),
        GGMLModel(name: "small.en", fileName: "ggml-small.en.bin", plainName: "Slow",
                  technicalName: "whisper.cpp small.en",
                  detail: "488 MB download — more accurate, slower", bytes: 487_614_201,
                  sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"),
    ]
}
