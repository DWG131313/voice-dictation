import Foundation

public protocol ModelManagerDelegate: AnyObject {
    func modelDownloadProgress(_ progress: Double)
    func modelDownloadCompleted()
    func modelDownloadFailed(error: String)
}

public class ModelManager: NSObject {
    public weak var delegate: ModelManagerDelegate?

    private static let modelFileName = "ggml-base.en.bin"
    private static let downloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/v1.5.4/ggml-base.en.bin")!
    private static let expectedMinSize: Int64 = 140_000_000 // ~148MB, use min threshold

    private var downloadTask: URLSessionDownloadTask?
    private var urlSession: URLSession!
    private var retryCount = 0
    private static let maxRetries = 3

    public var modelDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("VoiceDictation/models")
    }

    public var modelFileURL: URL {
        modelDirectoryURL.appendingPathComponent(Self.modelFileName)
    }

    public var isModelPresent: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelFileURL.path) else { return false }
        guard let attrs = try? fm.attributesOfItem(atPath: modelFileURL.path),
              let size = attrs[.size] as? Int64 else { return false }
        return size >= Self.expectedMinSize
    }

    public override init() {
        super.init()
        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    public func downloadModelIfNeeded() {
        if isModelPresent {
            delegate?.modelDownloadCompleted()
            return
        }

        // Create directory
        try? FileManager.default.createDirectory(at: modelDirectoryURL, withIntermediateDirectories: true)

        startDownload()
    }

    private func startDownload() {
        retryCount += 1
        downloadTask = urlSession.downloadTask(with: Self.downloadURL)
        downloadTask?.resume()
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            // Remove existing file if present (partial/corrupt)
            if FileManager.default.fileExists(atPath: modelFileURL.path) {
                try FileManager.default.removeItem(at: modelFileURL)
            }
            try FileManager.default.moveItem(at: location, to: modelFileURL)

            if isModelPresent {
                retryCount = 0
                delegate?.modelDownloadCompleted()
            } else {
                try? FileManager.default.removeItem(at: modelFileURL)
                handleDownloadFailure(error: "Downloaded file is too small — may be corrupted")
            }
        } catch {
            handleDownloadFailure(error: error.localizedDescription)
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        delegate?.modelDownloadProgress(progress)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            handleDownloadFailure(error: error.localizedDescription)
        }
    }

    private func handleDownloadFailure(error: String) {
        if retryCount < Self.maxRetries {
            let delay = pow(2.0, Double(retryCount)) // Exponential backoff: 2, 4, 8 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.startDownload()
            }
        } else {
            retryCount = 0
            delegate?.modelDownloadFailed(error: "Model download failed after \(Self.maxRetries) attempts: \(error)")
        }
    }
}
