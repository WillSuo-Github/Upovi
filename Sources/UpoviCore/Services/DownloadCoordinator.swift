import Foundation

/// Pausing cancels only the current transfer. Its caller remains suspended until resume/cancel.
public actor DownloadCoordinator {
    public static let shared = DownloadCoordinator(cache: .shared,
        storageURL: URL.applicationSupportDirectory.appending(path: "Upovi/Downloads/tasks-v1.json"))
    typealias Transfer = @Sendable (DownloadDescriptor, InstalledApp, URL, @escaping @Sendable (ArtifactDownloadPhase) -> Void,
                                   @escaping @Sendable (Int64) -> Void, @escaping @Sendable (Int64, Int64) -> Void) async throws -> Void
    private struct Control {
        var paused = false
        var cancelled = false
        var generation = 0
        var work: Task<Void, any Error>?
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let transfer: Transfer
    private let storageURL: URL?
    private let retryDelay: Duration
    private var historyReadable = true
    private var online = true
    private var controls: [UUID: Control] = [:]
    private var records: [DownloadRecord] = []
    private var listeners: [UUID: AsyncStream<[DownloadRecord]>.Continuation] = [:]
    private var lastProgressSave: [UUID: Date] = [:]
    private(set) public var historySaveFailed = false

    public init(cache: ArtifactDownloadCache = .shared, storageURL: URL? = nil) {
        self.storageURL = storageURL; retryDelay = .seconds(2)
        transfer = { descriptor, app, destination, phase, resume, progress in
            try await cache.download(descriptor, app: app, to: destination, onPhase: phase, onResume: resume, progress: progress)
        }
        let history = Self.load(storageURL); records = history.records; historyReadable = history.readable; historySaveFailed = !history.readable
    }
    init(storageURL: URL? = nil, retryDelay: Duration = .milliseconds(10), transfer: @escaping Transfer) {
        self.storageURL = storageURL; self.retryDelay = retryDelay; self.transfer = transfer
        let history = Self.load(storageURL); records = history.records; historyReadable = history.readable; historySaveFailed = !history.readable
    }
    private static func load(_ url: URL?) -> (records: [DownloadRecord], readable: Bool) {
        guard let url else { return ([], true) }
        let files = FileManager.default
        if (try? files.destinationOfSymbolicLink(atPath: url.path)) != nil { return ([], false) }
        guard files.fileExists(atPath: url.path) else { return ([], true) }
        guard let info = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
              info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 1_000_000,
              let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return ([], false) }
        var seen = Set<UUID>()
        let records = values.filter { seen.insert($0.id).inserted }.prefix(50).map {
            var value = $0
            if value.state.active { value.state = .interrupted; value.updatedAt = Date() }
            return value
        }
        return (records, true)
    }
    public func snapshots() -> AsyncStream<[DownloadRecord]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            listeners[id] = continuation; continuation.yield(records)
            continuation.onTermination = { @Sendable _ in Task { await self.removeListener(id) } }
        }
    }
    private func removeListener(_ id: UUID) { listeners[id] = nil }
    public func snapshot() -> [DownloadRecord] { records }
    private func publish(save: Bool = true) {
        if save, let url = storageURL, historyReadable {
            do {
                let parent = url.deletingLastPathComponent(), files = FileManager.default
                guard parent.resolvingSymlinksInPath().path == parent.path else { throw PeerError.invalid("Linked download history") }
                try files.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if files.fileExists(atPath: url.path), try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw PeerError.invalid("Linked download history") }
                try JSONEncoder().encode(records).write(to: url, options: .atomic)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                historySaveFailed = false
            } catch { historySaveFailed = true }
        }
        for listener in listeners.values { listener.yield(records) }
    }
    private func update(_ id: UUID, _ change: (inout DownloadRecord) -> Void, save: Bool = true) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[i]); records[i].updatedAt = Date(); publish(save: save)
    }
    public func pause(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }), record.state.canPause, controls[id] != nil else { return }
        controls[id]?.paused = true; controls[id]?.generation += 1; controls[id]?.work?.cancel()
        update(id) { $0.state = .paused }
    }
    public func resume(_ id: UUID) {
        guard controls[id]?.paused == true else { return }
        controls[id]?.paused = false
        update(id) { $0.state = online ? .queued : .waitingForNetwork }
        wake(id)
    }
    public func cancel(_ id: UUID) {
        guard controls[id] != nil else { return }
        controls[id]?.cancelled = true; controls[id]?.work?.cancel(); wake(id)
    }
    private func wake(_ id: UUID) {
        let waiter = controls[id]?.waiter; controls[id]?.waiter = nil; waiter?.resume()
    }
    public func setOnline(_ value: Bool) {
        guard online != value else { return }
        online = value
        for id in Array(controls.keys) {
            if !value, let state = records.first(where: { $0.id == id })?.state, [.downloading, .retrying].contains(state) {
                controls[id]?.generation += 1; controls[id]?.work?.cancel()
            }
            wake(id)
        }
    }
    public static func retryable(_ error: any Error) -> Bool {
        if let http = error as? HTTPStatusError { return [408, 429, 500, 502, 503, 504].contains(http.statusCode) }
        let value = error as NSError
        return value.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotFindHost].contains(value.code)
    }
    public func download(_ descriptor: DownloadDescriptor, app: InstalledApp, targetVersion: String = "", to destination: URL,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: destination.path),
              (try? FileManager.default.attributesOfItem(atPath: destination.path)) == nil else { throw PeerError.invalid("Download destination already exists") }
        guard controls.count < 10 else { throw PeerError.unavailable("Too many active artifact downloads") }
        let record = DownloadRecord(app: app, targetVersion: targetVersion), id = record.id
        records.insert(record, at: 0)
        // Never evict a caller that is currently suspended in this coordinator.
        let active = records.filter { controls[$0.id] != nil }
        records = [record] + active + records.filter { $0.id != id && controls[$0.id] == nil }.prefix(max(0, 49 - active.count))
        controls[id] = Control(); publish()
        defer { controls[id] = nil; lastProgressSave[id] = nil }
        do {
            try await withTaskCancellationHandler {
                try await run(id, descriptor: descriptor, app: app, destination: destination, progress: progress)
            } onCancel: { Task { await self.cancel(id) } }
            try Task.checkCancellation()
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value
            update(id) { $0.state = .verified; $0.issue = nil; if let bytes { $0.received = bytes; $0.expected = bytes } }
        } catch {
            update(id) { $0.state = error is CancellationError || Task.isCancelled ? .cancelled : .failed; $0.issue = .init(error) }
            throw error
        }
    }
    private func run(_ id: UUID, descriptor: DownloadDescriptor, app: InstalledApp, destination: URL,
                     progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        var retryCount = 0
        while true {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try Task.checkCancellation()
            guard controls[id]?.cancelled == false else { throw CancellationError() }
            if controls[id]?.paused == true || !online {
                update(id) { $0.state = controls[id]?.paused == true ? .paused : .waitingForNetwork }
                await withCheckedContinuation { controls[id]?.waiter = $0 }
                continue
            }
            controls[id]?.generation += 1
            let generation = controls[id]!.generation
            update(id) { $0.state = .downloading; $0.issue = nil }
            let operation = transfer
            let work = Task {
                try await operation(descriptor, app, destination,
                    { phase in Task { await self.phase(id, generation: generation, phase: phase) } },
                    { offset in Task { await self.resumed(id, generation: generation, offset: offset) } },
                    { received, expected in
                        progress(received, expected)
                        Task { await self.progress(id, generation: generation, received: received, expected: expected) }
                    })
            }
            controls[id]?.work = work
            do {
                try await work.value; controls[id]?.work = nil
                guard controls[id]?.cancelled == false else { throw CancellationError() }
                return
            } catch {
                controls[id]?.work = nil
                if Task.isCancelled || controls[id]?.cancelled != false { throw CancellationError() }
                if controls[id]?.generation != generation || controls[id]?.paused == true || !online { continue }
                guard Self.retryable(error), retryCount < 3 else { throw error }
                retryCount += 1
                update(id) { $0.state = .retrying; $0.retries = retryCount; $0.issue = .init(error) }
                let delay = retryDelay * retryCount
                let backoff = Task { try await Task.sleep(for: delay) }
                controls[id]?.work = backoff
                do { try await backoff.value } catch { }
                controls[id]?.work = nil
            }
        }
    }
    private func phase(_ id: UUID, generation: Int, phase: ArtifactDownloadPhase) {
        guard controls[id]?.generation == generation, controls[id]?.cancelled == false, controls[id]?.paused == false,
              let state = records.first(where: { $0.id == id })?.state, [.downloading, .verifying].contains(state) else { return }
        update(id) { $0.state = phase == .verifying ? .verifying : .downloading }
    }
    private func resumed(_ id: UUID, generation: Int, offset: Int64) {
        guard controls[id]?.generation == generation, controls[id]?.cancelled == false else { return }
        update(id) { $0.resumedBytes = offset }
    }
    private func progress(_ id: UUID, generation: Int, received: Int64, expected: Int64) {
        guard controls[id]?.generation == generation, controls[id]?.paused == false, controls[id]?.cancelled == false,
              records.first(where: { $0.id == id })?.state == .downloading else { return }
        let save = Date().timeIntervalSince(lastProgressSave[id] ?? .distantPast) >= 1
        if save { lastProgressSave[id] = Date() }
        update(id, { $0.received = max(0, received); $0.expected = expected }, save: save)
    }
}
