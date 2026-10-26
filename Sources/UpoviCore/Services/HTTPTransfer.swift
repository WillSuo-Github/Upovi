import Foundation
import Darwin

public struct HTTPStatusError: LocalizedError, Sendable {
    public let statusCode: Int
    public let retryAt: Date?
    public let rateLimited: Bool
    public init(statusCode: Int, retryAt: Date? = nil, rateLimited: Bool = false) {
        self.statusCode = statusCode; self.retryAt = retryAt; self.rateLimited = rateLimited || statusCode == 429
    }
    static func response(_ response: HTTPURLResponse, now: Date = Date()) -> Self {
        let status = response.statusCode
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap { value -> Date? in
            if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return now.addingTimeInterval(min(seconds, 86400)) }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            return formatter.date(from: value).map { min($0, now.addingTimeInterval(86400)) }
        }
        let githubLimit = response.url?.host?.lowercased() == "api.github.com" && remaining == "0"
        let reset = githubLimit ? response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init)
            .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil } : nil
        let limited = status == 429 || (status == 403 && (githubLimit || retry != nil))
        let deadline = [retry, reset].compactMap { $0 }.max().map { min(max($0, now), now.addingTimeInterval(86400)) }
        return .init(statusCode: status, retryAt: deadline, rateLimited: limited)
    }
    public var errorDescription: String? { "HTTP request failed with status \(statusCode)" }
}

struct DownloadResumeState: Codable {
    let url: URL
    let etag: String
    let total: Int64
    static func validETag(_ value: String) -> Bool {
        guard value.utf8.count <= 512, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let range = value.range(of: #"^"[\x21\x23-\x7E]*"$"#, options: .regularExpression) else { return false }
        return range.lowerBound == value.startIndex && range.upperBound == value.endIndex
    }
    static func metadata(for destination: URL) -> URL { destination.appendingPathExtension("resume.json") }
}

enum DownloadRestart: Error { case required }

struct HTTPMetadataResponse: Sendable {
    let data: Data
    let status: Int
    let headers: [String: String]
}

public enum HTTPTransfer {
    static func metadata(from url: URL, limit: Int, headers: [String: String],
                         configuration: URLSessionConfiguration = .ephemeral) async throws -> HTTPMetadataResponse {
        let transfer = Transfer(url: url, limit: Int64(limit), destination: nil, progress: nil,
                                configuration: configuration, metadataHeaders: headers)
        let data = try await transfer.run()
        return transfer.metadataResult(data)
    }
    public static func data(from url: URL, limit: Int) async throws -> Data {
        let result = try await Transfer(url: url, limit: Int64(limit), destination: nil, progress: nil).run()
        return result
    }
    public static func download(from url: URL, to destination: URL, limit: Int64 = 2_000_000_000,
                                resuming: Bool = false,
                                onResume: @escaping @Sendable (Int64) -> Void = { _ in },
                                progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        try await download(from: url, to: destination, limit: limit, resuming: resuming, configuration: .ephemeral, onResume: onResume, progress: progress)
    }
    static func download(from url: URL, to destination: URL, limit: Int64, resuming: Bool,
                         configuration: URLSessionConfiguration, onResume: @escaping @Sendable (Int64) -> Void = { _ in }, progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        do {
            _ = try await Transfer(url: url, limit: limit, destination: destination, progress: progress, resuming: resuming, configuration: configuration, onResume: onResume).run()
        } catch DownloadRestart.required {
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: DownloadResumeState.metadata(for: destination))
            _ = try await Transfer(url: url, limit: limit, destination: destination, progress: progress, resuming: false, configuration: configuration).run()
        }
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
    private let resuming: Bool
    private let configuration: URLSessionConfiguration
    private let onResume: @Sendable (Int64) -> Void
    private let metadataHeaders: [String: String]?
    private var responseStatus = 0
    private var conditionalMetadata = false
    private var responseHeaders: [String: String] = [:]
    func metadataResult(_ data: Data) -> HTTPMetadataResponse {
        lock.withLock { .init(data: data, status: responseStatus, headers: responseHeaders) }
    }
    private var resumeState: DownloadResumeState?
    private var offset: Int64 = 0

    init(url: URL, limit: Int64, destination: URL?, progress: (@Sendable (Int64, Int64) -> Void)?,
         resuming: Bool = false, configuration: URLSessionConfiguration = .ephemeral, metadataHeaders: [String: String]? = nil, onResume: @escaping @Sendable (Int64) -> Void = { _ in }) {
        self.url = url; self.limit = limit; self.destination = destination; self.progress = progress
        self.resuming = resuming; self.configuration = configuration; self.metadataHeaders = metadataHeaders
        self.onResume = onResume
    }
    func run() async throws -> Data {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.host != nil else { throw URLError(.unsupportedURL) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                do {
                    if let destination {
                        let fd = open(destination.path, O_CREAT | O_WRONLY | O_NOFOLLOW, 0o600)
                        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
                        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                        var attributes = stat()
                        guard fstat(fd, &attributes) == 0, attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                              attributes.st_uid == geteuid(), attributes.st_nlink == 1, attributes.st_size <= limit else {
                            try? handle.close(); throw PeerError.invalid("Unsafe partial download file")
                        }
                        let metadata = DownloadResumeState.metadata(for: destination)
                        if resuming, let info = try? metadata.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
                           info.isSymbolicLink != true, (info.fileSize ?? Int.max) < 16_384,
                           let data = try? Data(contentsOf: metadata), let state = try? JSONDecoder().decode(DownloadResumeState.self, from: data),
                           state.url == url, DownloadResumeState.validETag(state.etag), state.total > 0, state.total <= limit,
                           attributes.st_size > 0, attributes.st_size < state.total {
                            resumeState = state; offset = attributes.st_size; received = offset
                            try handle.seek(toOffset: UInt64(offset))
                        } else {
                            try handle.truncate(atOffset: 0); try? FileManager.default.removeItem(at: metadata)
                        }
                        file = handle
                    }
                    self.continuation = continuation
                    let config = configuration.copy() as! URLSessionConfiguration
                    config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 300
                    config.urlCredentialStorage = nil; config.httpShouldSetCookies = false; config.httpCookieStorage = nil
                    if destination != nil || metadataHeaders != nil { config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData }
                    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                    self.session = session
                    var request = URLRequest(url: url)
                    request.setValue("Upovi (macOS)", forHTTPHeaderField: "User-Agent")
                    if let metadataHeaders {
                        for (key, value) in metadataHeaders { request.setValue(value, forHTTPHeaderField: key) }
                        conditionalMetadata = metadataHeaders["If-None-Match"] != nil || metadataHeaders["If-Modified-Since"] != nil
                    }
                    if destination != nil { request.setValue("identity", forHTTPHeaderField: "Accept-Encoding") }
                    if let state = resumeState {
                        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
                        request.setValue(state.etag, forHTTPHeaderField: "If-Range")
                    }
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
        var redirected = request
        if request.url?.host?.lowercased() != response.url?.host?.lowercased() || request.url?.port != response.url?.port {
            redirected.setValue(nil, forHTTPHeaderField: "If-None-Match")
            redirected.setValue(nil, forHTTPHeaderField: "If-Modified-Since")
            lock.withLock { conditionalMetadata = false }
        }
        if destination != nil { redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding") }
        if let state = resumeState {
            redirected.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            redirected.setValue(state.etag, forHTTPHeaderField: "If-Range")
        }
        completionHandler(redirected)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        do {
            guard let http = response as? HTTPURLResponse, response.url?.scheme == "https" else { throw URLError(.badServerResponse) }
            if http.statusCode == 416 && offset > 0 { throw DownloadRestart.required }
            responseStatus = http.statusCode
            for key in ["ETag", "Last-Modified", "Cache-Control", "Vary"] {
                if let value = http.value(forHTTPHeaderField: key) { responseHeaders[key.lowercased()] = value }
            }
            if metadataHeaders != nil, http.statusCode == 304 {
                guard conditionalMetadata else { throw URLError(.badServerResponse) }
                lock.unlock(); completionHandler(.allow); return
            }
            guard (200..<300).contains(http.statusCode) else { throw HTTPStatusError.response(http) }
            guard response.expectedContentLength <= limit else { throw URLError(.badServerResponse) }
            if let destination {
                let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
                guard encoding == nil || encoding == "identity" else { throw DownloadRestart.required }
                if http.statusCode == 206 {
                    guard let state = resumeState, offset > 0,
                          http.value(forHTTPHeaderField: "ETag") == state.etag,
                          let range = http.value(forHTTPHeaderField: "Content-Range"),
                          let parsed = Self.parseRange(range), parsed.start == offset, parsed.total == state.total,
                          parsed.end >= parsed.start, parsed.end < parsed.total,
                          response.expectedContentLength < 0 || response.expectedContentLength == parsed.end - parsed.start + 1 else { throw DownloadRestart.required }
                    expected = parsed.total
                } else {
                    guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
                    try file?.truncate(atOffset: 0); try file?.seek(toOffset: 0)
                    offset = 0; received = 0; expected = response.expectedContentLength
                    try? FileManager.default.removeItem(at: DownloadResumeState.metadata(for: destination))
                }
                if let etag = http.value(forHTTPHeaderField: "ETag"), DownloadResumeState.validETag(etag), expected > 0 {
                    let state = DownloadResumeState(url: url, etag: etag, total: expected)
                    let metadata = DownloadResumeState.metadata(for: destination)
                    try JSONEncoder().encode(state).write(to: metadata, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
                }
            } else { expected = response.expectedContentLength }
            let resumedOffset = offset, total = expected
            lock.unlock()
            if resumedOffset > 0 { onResume(resumedOffset); progress?(resumedOffset, total) }
            completionHandler(.allow)
        } catch {
            failure = error; lock.unlock(); completionHandler(.cancel)
        }
    }
    private static func parseRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        guard let regex = try? NSRegularExpression(pattern: #"^bytes ([0-9]+)-([0-9]+)/([0-9]+)$"#),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        let fields = (1...3).compactMap { index -> Int64? in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return Int64(value[range])
        }
        guard fields.count == 3, fields[0] >= 0, fields[2] > 0 else { return nil }
        return (fields[0], fields[1], fields[2])
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var update: (Int64, Int64)?
        lock.lock()
        do {
            guard received + Int64(data.count) <= limit else { throw URLError(.dataLengthExceedsMaximum) }
            if destination != nil, expected >= 0, received + Int64(data.count) > expected { throw URLError(.badServerResponse) }
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
        do { try file?.synchronize(); try file?.close() } catch { self.failure = error }
        let incomplete = destination != nil && expected >= 0 && received != expected ? URLError(.networkConnectionLost) : nil
        let finalError = failure ?? self.failure ?? incomplete
        let result = buffer
        self.task = nil; self.file = nil; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let finalError { continuation?.resume(throwing: finalError) } else { continuation?.resume(returning: result) }
    }
}
