import Foundation

public enum HTTPTransfer {
    public static func data(from url: URL, limit: Int) async throws -> Data {
        let result = try await Transfer(url: url, limit: Int64(limit), destination: nil, progress: nil).run()
        return result
    }
    public static func download(from url: URL, to destination: URL, limit: Int64 = 2_000_000_000,
                                progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        _ = try await Transfer(url: url, limit: limit, destination: destination, progress: progress).run()
    }
}

private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let limit: Int64
    private let destination: URL?
    private let progress: (@Sendable (Int64, Int64) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Data, any Error>?
    private var file: FileHandle?
    private var buffer = Data()
    private var received: Int64 = 0
    private var expected: Int64 = -1
    private var failure: (any Error)?
    private var cancelled = false
    private var lastProgress = Date.distantPast

    init(url: URL, limit: Int64, destination: URL?, progress: (@Sendable (Int64, Int64) -> Void)?) {
        self.url = url; self.limit = limit; self.destination = destination; self.progress = progress
    }
    func run() async throws -> Data {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.host != nil else { throw URLError(.unsupportedURL) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                do {
                    if let destination {
                        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                        file = try FileHandle(forWritingTo: destination)
                    }
                    self.continuation = continuation
                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 300
                    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                    self.session = session
                    var request = URLRequest(url: url)
                    request.setValue("Upovi (macOS)", forHTTPHeaderField: "User-Agent")
                    let task = session.dataTask(with: request); self.task = task
                    lock.unlock(); task.resume()
                } catch { lock.unlock(); continuation.resume(throwing: error) }
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true; let task = self.task; self.lock.unlock(); task?.cancel()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.user == nil, request.url?.password == nil else {
            lock.withLock { failure = URLError(.unsupportedURL) }; completionHandler(nil); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), response.url?.scheme == "https",
              response.expectedContentLength <= limit else {
            lock.withLock { failure = URLError(.badServerResponse) }; completionHandler(.cancel); return
        }
        lock.withLock { expected = response.expectedContentLength }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var update: (Int64, Int64)?
        lock.lock()
        do {
            guard received + Int64(data.count) <= limit else { throw URLError(.dataLengthExceedsMaximum) }
            if let file { try file.write(contentsOf: data) } else { buffer.append(data) }
            received += Int64(data.count)
            if Date().timeIntervalSince(lastProgress) >= 0.15 {
                lastProgress = Date(); update = (received, expected)
            }
            lock.unlock()
        } catch { failure = error; lock.unlock(); dataTask.cancel() }
        if let update { progress?(update.0, update.1) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let continuation = self.continuation; self.continuation = nil
        let failure = cancelled ? CancellationError() : self.failure ?? error
        do { try file?.close() } catch { self.failure = error }
        let finalError = failure ?? self.failure
        let result = buffer
        self.task = nil; self.file = nil; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let finalError { continuation?.resume(throwing: finalError) } else { continuation?.resume(returning: result) }
    }
}
