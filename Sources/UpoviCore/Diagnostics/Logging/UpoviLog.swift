import Foundation
import OSLog
import Darwin

/// How serious an entry is.
public enum UpoviLogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case fault = 4

    public static func < (lhs: UpoviLogLevel, rhs: UpoviLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var name: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARNING"
        case .error: "ERROR"
        case .fault: "FAULT"
        }
    }
}

/// Categories match update diagnosis rather than the source file layout.
public enum UpoviLogCategory: String, CaseIterable, Sendable {
    case app, scan, sources, network, downloads, authorization, installation, recovery
    case tools, storage, community, selfUpdate, diagnostics, process
}

/// Adapted from Vunio's rotating logger; file IO stays off the calling actor.
public struct UpoviLogConfiguration: Sendable {
    public var writesToConsole = true
    public var writesToFile = true
    public var minimumLevel: UpoviLogLevel = .debug
    public init() { }
    /// Rotate once a file passes this size.
    public var maximumFileByteCount: UInt64 = 5 * 1_024 * 1_024
    /// Delete the oldest files once the directory passes this size.
    public var maximumTotalByteCount: UInt64 = 40 * 1_024 * 1_024

    /// Age is a ceiling; the size budget may evict files sooner.
    public var maximumRetentionDays: Int = 14
    public var maximumRetainedFileCount: Int = 200
    public var maximumPendingByteCount: Int = 1_024 * 1_024

    /// A shipping build keeps `info` and above.
    ///
    /// Shipping logs retain operational boundaries, state transitions and errors.
    /// Development-only details must not crowd out those records.
    public static let release = { var value = UpoviLogConfiguration(); value.minimumLevel = .info; return value }()
    public static let development = UpoviLogConfiguration()

    var normalized: Self {
        var value = self
        value.maximumFileByteCount = min(maximumFileByteCount, 5 * 1024 * 1024)
        value.maximumTotalByteCount = min(maximumTotalByteCount, 40 * 1024 * 1024)
        value.maximumRetentionDays = min(max(0, maximumRetentionDays), 14)
        value.maximumPendingByteCount = min(max(0, maximumPendingByteCount), 1024 * 1024)
        value.maximumRetainedFileCount = min(max(1, maximumRetainedFileCount), 200)
        return value
    }

    public static var `default`: UpoviLogConfiguration {
        #if DEBUG
        development
        #else
        release
        #endif
    }
}

/// A bounded asynchronous sink shared by every production diagnostic.
/// File handles, formatters, pruning, and export snapshots belong to one queue.
public final class UpoviLogManager: @unchecked Sendable {
    public static let shared: UpoviLogManager = {
        var configuration = UpoviLogConfiguration.default
        // Privileged helpers must not create user-controlled files as root. The host logs
        // typed IPC outcomes; helper console output is not mixed into its JSON protocol.
        if geteuid() == 0 { configuration.writesToFile = false }
        var directory: URL?
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["UPOVI_LOG_DIRECTORY"] { directory = URL(fileURLWithPath: path) }
        #endif
        return UpoviLogManager(directoryURL: directory, configuration: configuration)
    }()
    public static let maximumEntryByteCount = 16 * 1_024

    public let logDirectory: URL
    public let sessionID = UUID().uuidString

    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let writeQueue = DispatchQueue(label: "app.upovi.Upovi.log", qos: .utility)
    private let stateLock = NSLock()
    private var configuration: UpoviLogConfiguration
    private var pendingBytes = 0
    private var droppedEntries = 0
    private var fileFailure: String?
    private var loggers: [UpoviLogCategory: Logger] = [:]
    private var currentFileURL: URL?
    private var currentFileHandle: FileHandle?
    private var currentDay: String?
    private var fileSequence: UInt64 = 0

    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    public static func defaultLogDirectory(fileManager: FileManager = .default) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root.appendingPathComponent("Upovi/Logs", isDirectory: true)
    }

    public init(
        directoryURL: URL? = nil,
        configuration: UpoviLogConfiguration = .default,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileManager = fileManager
        self.configuration = configuration.normalized
        self.now = now
        let configuration = configuration.normalized
        logDirectory = (directoryURL ?? Self.defaultLogDirectory(fileManager: fileManager)).standardizedFileURL
        let subsystem = Bundle.main.bundleIdentifier ?? "app.upovi.Upovi"
        for category in UpoviLogCategory.allCases {
            loggers[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        writeQueue.async { [self] in
            guard configuration.writesToFile else { return }
            do {
                try prepareDirectory()
                try prune(configuration: configuration, date: now())
            } catch { recordFileFailure(error) }
        }
    }

    deinit { try? currentFileHandle?.close() }

    public func configure(_ configuration: UpoviLogConfiguration) {
        let configuration = configuration.normalized
        stateLock.lock()
        self.configuration = configuration.normalized
        writeQueue.async { [self] in
            do { try prune(configuration: configuration, date: now()) }
            catch { recordFileFailure(error) }
        }
        stateLock.unlock()
    }

    public func log(
        _ message: @autoclosure () -> String,
        level: UpoviLogLevel,
        category: UpoviLogCategory,
        file: String = #fileID,
        line: Int = #line
    ) {
        let configuration = currentConfiguration()
        guard level >= configuration.minimumLevel else { return }
        // Bound before regex work as well as before admission to the IO queue.
        let text = UpoviLogPrivacy.sanitize(String(decoding: message().utf8.prefix(Self.maximumEntryByteCount), as: UTF8.self))
        let origin = UpoviLogPrivacy.sanitize("\(String(URL(fileURLWithPath: file).lastPathComponent.prefix(256))):\(line)")
        if configuration.writesToConsole, let logger = loggers[category] {
            let output = "[\(origin)] \(text)"
            switch level {
            case .debug: logger.debug("\(output, privacy: .public)")
            case .info: logger.info("\(output, privacy: .public)")
            case .warning: logger.warning("\(output, privacy: .public)")
            case .error: logger.error("\(output, privacy: .public)")
            case .fault: logger.fault("\(output, privacy: .public)")
            }
        }
        guard configuration.writesToFile else { return }
        let date = now()
        let operation = UpoviDiagnosticContext.operationID ?? "none"
        // Admission and dispatch are ordered together so flush sees all accepted entries.
        let estimate = text.utf8.count + origin.utf8.count + 256
        stateLock.lock()
        let maximumPending = max(1, configuration.maximumPendingByteCount)
        let reserve = min(64 * 1024, maximumPending / 4)
        let budget = level >= .warning ? maximumPending : maximumPending - reserve
        guard pendingBytes + estimate <= budget else {
            droppedEntries += 1
            stateLock.unlock()
            return
        }
        pendingBytes += estimate
        writeQueue.async { [self] in
            defer {
                stateLock.lock()
                pendingBytes -= estimate
                stateLock.unlock()
            }
            let timestamp = timestampFormatter.string(from: date)
            let entry = "[\(timestamp)] [\(level.name)] [\(category.rawValue)] [session=\(sessionID)] [operation=\(operation)] [\(origin)] \(text)\n"
            do { try append(entry, configuration: configuration, date: date); if level >= .error { try currentFileHandle?.synchronize() } }
            catch { recordFileFailure(error) }
        }
        stateLock.unlock()
    }

    public func logFileURLs() -> [URL] {
        writeQueue.sync { files() }
    }

    /// A single serialized snapshot prevents rotation from removing files mid-export.
    /// Read failures propagate to the UI instead of producing an incomplete report.
    public func exportSnapshot() throws -> String {
        try writeQueue.sync {
            let configuration = currentConfiguration()
            _ = try fileManager.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil)
            try prune(configuration: configuration, date: now())
            try currentFileHandle?.synchronize()
            var sections: [String] = []
            stateLock.lock()
            let dropped = droppedEntries
            stateLock.unlock()
            sections.append("Retention: maxDays=\(configuration.maximumRetentionDays) maxFileBytes=\(configuration.maximumFileByteCount) maxTotalBytes=\(configuration.maximumTotalByteCount) maxFiles=\(configuration.maximumRetainedFileCount)\nSession: \(sessionID)\nDropped entries (busy writer): \(dropped)\nLast file IO failure: \(fileFailure ?? "none")\n")
            for url in files().reversed() {
                guard byteCount(of: url) <= configuration.maximumFileByteCount else { throw CocoaError(.fileReadTooLarge) }
                let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                var attributes = stat()
                guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
                      attributes.st_uid == getuid(), attributes.st_size >= 0,
                      attributes.st_size <= configuration.maximumFileByteCount else { throw CocoaError(.fileReadCorruptFile) }
                let bytes = try handle.read(upToCount: Int(configuration.maximumFileByteCount) + 1) ?? Data()
                guard bytes.count <= configuration.maximumFileByteCount, let text = String(data: bytes, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
                // Sanitize legacy files too, including ones from older app versions.
                let redacted = UpoviLogPrivacy.sanitize(text, preservesLineBreaks: true)
                sections.append("=== \(url.lastPathComponent) ===\n\(redacted)")
            }
            if files().isEmpty { sections.append("No retained log entries.") }
            return sections.joined(separator: "\n\n")
        }
    }

    public func combinedLogText() -> String {
        (try? exportSnapshot()) ?? "Log snapshot unavailable."
    }

    public func flush() {
        writeQueue.sync {
            do { try currentFileHandle?.synchronize() }
            catch { recordFileFailure(error) }
        }
    }

    public func flushAsync() async {
        await withCheckedContinuation { continuation in
            writeQueue.async { [self] in
                do { try currentFileHandle?.synchronize() }
                catch { recordFileFailure(error) }
                continuation.resume()
            }
        }
    }

    public func removeAllLogs() {
        writeQueue.sync {
            closeCurrentFile()
            for url in files() {
                do { try fileManager.removeItem(at: url) }
                catch { recordFileFailure(error) }
            }
        }
    }

    private func currentConfiguration() -> UpoviLogConfiguration {
        stateLock.lock()
        defer { stateLock.unlock() }
        return configuration
    }

    private func files() -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { url in
            guard url.pathExtension == "log", url.lastPathComponent.hasPrefix("Upovi-") else { return false }
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            return attributes?[.type] as? FileAttributeType == .typeRegular &&
                (attributes?[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
        }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func prepareDirectory() throws {
        guard logDirectory.deletingLastPathComponent().resolvingSymlinksInPath() == logDirectory.deletingLastPathComponent() else { throw CocoaError(.fileWriteInvalidFileName) }
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try fileManager.attributesOfItem(atPath: logDirectory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw CocoaError(.fileReadNoPermission) }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logDirectory.path)
        var directory = logDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    private func append(_ line: String, configuration: UpoviLogConfiguration, date: Date) throws {
        let limit = Int(min(configuration.maximumFileByteCount, configuration.maximumTotalByteCount,
                            UInt64(Self.maximumEntryByteCount)))
        guard limit > 0 else { return }
        let data = Self.boundedUTF8(line, limit: limit)
        try prune(configuration: configuration, date: date, incoming: UInt64(data.count))
        let day = String(timestampFormatter.string(from: date).prefix(10))
        if currentFileHandle == nil || currentDay != day ||
            byteCount(of: currentFileURL!) + UInt64(data.count) > configuration.maximumFileByteCount {
            closeCurrentFile()
            try prepareDirectory()
            // One file per session/day/rotation avoids resuming a file with expired entries.
            let stamp = timestampFormatter.string(from: date).replacingOccurrences(of: ":", with: "-")
            fileSequence += 1
            let sequence = String(format: "%012llu", fileSequence)
            let url = logDirectory.appendingPathComponent("Upovi-\(stamp)-\(sequence)-\(sessionID).log")
            let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            currentFileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            currentFileURL = url
            currentDay = day
        }
        try currentFileHandle?.write(contentsOf: data)
        try prune(configuration: configuration, date: date)
    }

    private static func boundedUTF8(_ line: String, limit: Int) -> Data {
        let data = Data(line.utf8)
        guard data.count > limit else { return data }
        let marker = Data(" [truncated]\n".utf8)
        guard limit >= marker.count else { return Data("\n".utf8.prefix(limit)) }
        var prefix = Data(data.prefix(limit - marker.count))
        while String(data: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        prefix.append(marker)
        return prefix
    }

    private func prune(configuration: UpoviLogConfiguration, date: Date, incoming: UInt64 = 0) throws {
        let cutoff = date.addingTimeInterval(-Double(max(0, configuration.maximumRetentionDays)) * 86_400)
        // Creation time bounds the oldest entry, even if a legacy file was appended recently.
        for url in files() {
            let values = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let oldest = min(values.creationDate ?? .distantFuture, values.contentModificationDate ?? .distantFuture)
            if oldest < cutoff || byteCount(of: url) > configuration.maximumFileByteCount {
                if url == currentFileURL { closeCurrentFile() }
                try fileManager.removeItem(at: url)
            }
        }
        let ordered = files()
        for url in ordered.dropFirst(max(1, configuration.maximumRetainedFileCount)) {
            if url == currentFileURL { closeCurrentFile() }
            try fileManager.removeItem(at: url)
        }
        let retained = files().reversed()
        var total = retained.reduce(UInt64(0)) { $0 + byteCount(of: $1) }
        for url in retained where total + incoming > configuration.maximumTotalByteCount {
            let size = byteCount(of: url)
            if url == currentFileURL { closeCurrentFile() }
            try fileManager.removeItem(at: url)
            total -= size
        }
    }

    private func closeCurrentFile() {
        try? currentFileHandle?.close()
        currentFileHandle = nil
        currentFileURL = nil
        currentDay = nil
    }

    private func recordFileFailure(_ error: Error) {
        let failure = error as NSError
        fileFailure = "domain=\(failure.domain) code=\(failure.code)"
        loggers[.app]?.error("Diagnostic file IO failed: \(failure.domain, privacy: .public) \(failure.code)")
        closeCurrentFile()
    }

    private func byteCount(of url: URL) -> UInt64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}

/// Category emitters are safe from UI actors, source tasks and transport callbacks.
/// Prefer fixed events, pseudonymous context and bounded error summaries.
public enum UpoviLog {
    public typealias Category = UpoviLogCategory

    public static func log(
        _ message: @autoclosure () -> String,
        level: UpoviLogLevel,
        category: UpoviLogCategory,
        file: String = #fileID,
        line: Int = #line
    ) {
        UpoviLogManager.shared.log(
            message(),
            level: level,
            category: category,
            file: file,
            line: line
        )
    }

    public struct Emitter: Sendable {
        let category: UpoviLogCategory

        public func debug(
            _ message: @autoclosure () -> String,
            file: String = #fileID,
            line: Int = #line
        ) {
            UpoviLogManager.shared.log(message(), level: .debug, category: category, file: file, line: line)
        }

        public func info(
            _ message: @autoclosure () -> String,
            file: String = #fileID,
            line: Int = #line
        ) {
            UpoviLogManager.shared.log(message(), level: .info, category: category, file: file, line: line)
        }

        public func warning(
            _ message: @autoclosure () -> String,
            file: String = #fileID,
            line: Int = #line
        ) {
            UpoviLogManager.shared.log(message(), level: .warning, category: category, file: file, line: line)
        }

        public func error(
            _ message: @autoclosure () -> String,
            file: String = #fileID,
            line: Int = #line
        ) {
            UpoviLogManager.shared.log(message(), level: .error, category: category, file: file, line: line)
        }

        public func fault(
            _ message: @autoclosure () -> String,
            file: String = #fileID,
            line: Int = #line
        ) {
            UpoviLogManager.shared.log(message(), level: .fault, category: category, file: file, line: line)
        }
    }

    public static let app = Emitter(category: .app)
    public static let scan = Emitter(category: .scan)
    public static let sources = Emitter(category: .sources)
    public static let network = Emitter(category: .network)
    public static let downloads = Emitter(category: .downloads)
    public static let authorization = Emitter(category: .authorization)
    public static let installation = Emitter(category: .installation)
    public static let recovery = Emitter(category: .recovery)
    public static let tools = Emitter(category: .tools)
    public static let storage = Emitter(category: .storage)
    public static let community = Emitter(category: .community)
    public static let selfUpdate = Emitter(category: .selfUpdate)
    public static let diagnostics = Emitter(category: .diagnostics)
    public static let process = Emitter(category: .process)
}
