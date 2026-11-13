import XCTest
@testable import VoiceDictationLib

/// The ggml downloader, against a `URLProtocol` stub that serves each
/// response from memory: the stub is the tests' session's only protocol and
/// accepts every request, so nothing reaches the network. Every file is
/// written in a fresh temporary folder.
final class GGMLDownloadTests: XCTestCase {
    /// 300 kB, served in three 100 kB chunks.
    private static let body = makeBody(count: 300_000)
    /// `body`'s SHA-256, worked out with Python's hashlib, not CryptoKit.
    private static let bodySHA256 = "5e58d6f559f0d43cd19c8e4c9189eb63de7db74cb3998001eeda37b1043720ce"

    private var root: URL!
    /// The models folder, which `fetch` makes.
    private var directory: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ggml-download-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directory = root.appendingPathComponent("models", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        // A stalled stub fails the request instead of hanging the suite.
        configuration.timeoutIntervalForRequest = 5
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        StubProtocol.script = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Downloads

    func testDownloadReportsProgressAndInstallsTheFile() async throws {
        StubProtocol.script = .init(chunks: Self.chunks(of: Self.body, count: 3))
        let model = Self.model()
        let progress = Values()

        try await GGMLDownload.fetch(model, into: directory, session: session) { progress.append($0) }

        let seen = progress.all
        XCTAssertEqual(seen.last, 1, "progress: \(seen)")
        XCTAssertTrue(seen.contains { $0 > 0 && $0 < 1 }, "progress came only at the end: \(seen)")
        XCTAssertEqual(seen, seen.sorted(), "progress went back: \(seen)")
        XCTAssertEqual(try Data(contentsOf: file(of: model)), Self.body)
        XCTAssertEqual(try contents(), [model.fileName], "a .partial was left")
        XCTAssertEqual(StubProtocol.requested, [model.url])
    }

    func testWrongChecksumLeavesNothing() async throws {
        StubProtocol.script = .init(chunks: Self.chunks(of: Self.body, count: 3))
        let model = Self.model(sha256: String(repeating: "0", count: 64))

        let error = await failure(of: model)

        guard case .failed(let reason)? = error as? TranscriptionError else { return XCTFail("threw \(String(describing: error))") }
        XCTAssertTrue(reason.contains("checksum"), reason)
        XCTAssertEqual(try contents(), [], "a file was left behind")
    }

    func testHTTPErrorLeavesNothing() async throws {
        StubProtocol.script = .init(status: 404, chunks: [Data("Entry not found".utf8)])

        let error = await failure(of: Self.model())

        guard case .failed(let reason)? = error as? TranscriptionError else { return XCTFail("threw \(String(describing: error))") }
        XCTAssertTrue(reason.contains("HTTP 404"), reason)
        XCTAssertEqual(try contents(), [], "a file was left behind")
    }

    func testCancelLeavesNothing() async throws {
        // The first chunk, then nothing until the download is cancelled.
        StubProtocol.script = .init(chunks: Self.chunks(of: Self.body, count: 3), stallAfter: 1)
        let model = Self.model()
        let progress = Values()
        let directory = directory!
        let session = session!
        let download = Task { try await GGMLDownload.fetch(model, into: directory, session: session) { progress.append($0) } }
        let deadline = ContinuousClock.now + .seconds(2)
        while progress.all.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(progress.all, [100_000.0 / 300_000], "the first chunk did not arrive")

        download.cancel()

        guard let result = await result(of: download, within: 2) else { return XCTFail("still downloading 2 s after the cancel") }
        guard case .failure(let error) = result else { return XCTFail("finished instead of stopping") }
        XCTAssertTrue(error is CancellationError, "threw \(error), not CancellationError")
        XCTAssertEqual(try contents(), [], "a file was left behind")
    }

    func testCatalogUsesMainBranch() {
        for model in GGMLModel.all {
            XCTAssertEqual(model.url.absoluteString,
                           "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(model.fileName)")
        }
    }

    // MARK: - Beyond the brief's list: the size check, a stale .partial, and the hash's chunks

    func testWrongSizeLeavesNothing() async throws {
        StubProtocol.script = .init(chunks: Self.chunks(of: Self.body, count: 3))
        let model = Self.model(bytes: 300_001)

        let error = await failure(of: model)

        guard case .failed(let reason)? = error as? TranscriptionError else { return XCTFail("threw \(String(describing: error))") }
        XCTAssertTrue(reason.contains("300000") && reason.contains("300001"), reason)
        XCTAssertEqual(try contents(), [], "a file was left behind")
    }

    /// A `.partial` left by an earlier run, say one the app was quit during,
    /// is removed before the download starts.
    func testAStalePartialIsReplaced() async throws {
        StubProtocol.script = .init(chunks: Self.chunks(of: Self.body, count: 3))
        let model = Self.model()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("left from before".utf8).write(to: directory.appendingPathComponent(model.fileName + ".partial"))

        try await GGMLDownload.fetch(model, into: directory, session: session) { _ in }

        XCTAssertEqual(try Data(contentsOf: file(of: model)), Self.body)
        XCTAssertEqual(try contents(), [model.fileName])
    }

    /// The hash reads the file 1 MB at a time; 2.5 MB takes three reads.
    func testChecksumCoversEveryChunkOfTheFile() throws {
        let url = root.appendingPathComponent("hash-me.bin")
        try Self.makeBody(count: 2_500_000).write(to: url)

        // Worked out with Python's hashlib.
        XCTAssertEqual(try GGMLDownload.sha256(of: url),
                       "08e9c1ef4f318e0fee3b10653ee5bef557aa68bd1689dcfab0ca3de66525ab96")
    }

    // MARK: - Helpers

    /// A catalog entry that `body` matches unless told otherwise.
    private static func model(bytes: Int64 = Int64(body.count), sha256: String = bodySHA256) -> GGMLModel {
        GGMLModel(name: "test.en", fileName: "ggml-test.en.bin", displayName: "whisper.cpp test.en",
                  detail: "", bytes: bytes, sha256: sha256)
    }

    /// Bytes that never repeat a 1 MB pattern, so a hash that read one chunk
    /// twice would differ.
    private static func makeBody(count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 4096) })
    }

    private static func chunks(of data: Data, count: Int) -> [Data] {
        let size = data.count / count
        return (0..<count).map { index in
            let end = index == count - 1 ? data.count : (index + 1) * size
            return data.subdata(in: index * size..<end)
        }
    }

    private func file(of model: GGMLModel) -> URL {
        directory.appendingPathComponent(model.fileName)
    }

    /// The models folder's files, by name.
    private func contents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// What `fetch` threw, or nil if it finished.
    private func failure(of model: GGMLModel) async -> Error? {
        do {
            try await GGMLDownload.fetch(model, into: directory, session: session) { _ in }
            return nil
        } catch {
            return error
        }
    }

    /// The task's result, or nil if it is still running after `limit` seconds.
    private func result(of task: Task<Void, Error>, within limit: TimeInterval) async -> Result<Void, Error>? {
        let ended = XCTestExpectation(description: "the download ended")
        Task {
            _ = await task.result
            ended.fulfill()
        }
        guard await XCTWaiter().fulfillment(of: [ended], timeout: limit) == .completed else { return nil }
        return await task.result
    }

    /// Values reported from any thread, in order.
    private final class Values: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []

        var all: [Double] { lock.withLock { values } }
        func append(_ value: Double) { lock.withLock { values.append(value) } }
    }
}

/// Answers every request from `script`: the status, then each chunk 20 ms
/// apart, then the end. With `stallAfter`, it stops sending after that many
/// chunks and waits to be cancelled.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Script: Sendable {
        var status = 200
        var chunks: [Data]
        var stallAfter: Int?
    }

    /// The current test's script, and the URLs asked for since it was set.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var script: Script?
        var requested: [URL] = []
    }

    private static let shared = Shared()

    static var script: Script? {
        get { shared.lock.withLock { shared.script } }
        set { shared.lock.withLock { shared.script = newValue; shared.requested = [] } }
    }

    static var requested: [URL] { shared.lock.withLock { shared.requested } }

    /// Sends the chunks in order. `stopped` is only touched on it.
    private let queue = DispatchQueue(label: "GGMLDownloadTests.StubProtocol")
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let script = Self.script else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        Self.shared.lock.withLock { Self.shared.requested.append(url) }
        let length = script.chunks.reduce(0) { $0 + $1.count }
        let response = HTTPURLResponse(url: url, statusCode: script.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(length)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        queue.async { self.send(script, from: 0) }
    }

    override func stopLoading() {
        queue.async { self.stopped = true }
    }

    private func send(_ script: Script, from index: Int) {
        guard !stopped else { return }
        guard index < script.chunks.count else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if let stall = script.stallAfter, index >= stall { return }
        client?.urlProtocol(self, didLoad: script.chunks[index])
        queue.asyncAfter(deadline: .now() + 0.02) { self.send(script, from: index + 1) }
    }
}
