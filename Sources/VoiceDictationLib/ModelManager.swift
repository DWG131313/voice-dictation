import Foundation

public protocol ModelManagerDelegate: AnyObject {
    func modelDownloadProgress(_ progress: Double)
    func modelDownloadCompleted()
    func modelDownloadFailed(error: String)
}

public class ModelManager: NSObject {
    public weak var delegate: ModelManagerDelegate?

    private var downloadTask: URLSessionDownloadTask?
    private var urlSession: URLSession!
    private var retryCount = 0
    private static let maxRetries = 3

    // Minimum sizes per model to detect corruption (approximate)
    private static let minSizes: [String: Int64] = [
        "tiny.en": 70_000_000,
        "base.en": 140_000_000,
        "small.en": 450_000_000,
    ]

    public var modelDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("VoiceDictation/models")
    }

    public var modelFileURL: URL {
        let model = PreferencesManager.shared.selectedModel
        return modelDirectoryURL.appendingPathComponent(model.fileName)
    }

    public var isModelPresent: Bool {
        let model = PreferencesManager.shared.selectedModel
        let url = modelDirectoryURL.appendingPathComponent(model.fileName)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return false }
        let minSize = Self.minSizes[model.id] ?? 50_000_000
        return size >= minSize
    }

    /// Check if a specific model is downloaded
    public func isModelDownloaded(_ model: PreferencesManager.WhisperModel) -> Bool {
        let url = modelDirectoryURL.appendingPathComponent(model.fileName)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return false }
        let minSize = Self.minSizes[model.id] ?? 50_000_000
        return size >= minSize
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

        try? FileManager.default.createDirectory(at: modelDirectoryURL, withIntermediateDirectories: true)
        startDownload()
    }

    /// Switch to a different model, downloading if necessary
    public func switchModel(to modelId: String) {
        PreferencesManager.shared.selectedModelId = modelId

        if isModelPresent {
            delegate?.modelDownloadCompleted()
        } else {
            retryCount = 0
            try? FileManager.default.createDirectory(at: modelDirectoryURL, withIntermediateDirectories: true)
            startDownload()
        }
    }

    private func startDownload() {
        retryCount += 1
        let model = PreferencesManager.shared.selectedModel
        downloadTask = urlSession.downloadTask(with: model.downloadURL)
        downloadTask?.resume()
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let destURL = modelFileURL
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: location, to: destURL)

            if isModelPresent {
                retryCount = 0
                delegate?.modelDownloadCompleted()
            } else {
                try? FileManager.default.removeItem(at: destURL)
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
            let delay = pow(2.0, Double(retryCount))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.startDownload()
            }
        } else {
            retryCount = 0
            delegate?.modelDownloadFailed(error: "Model download failed after \(Self.maxRetries) attempts: \(error)")
        }
    }
}
