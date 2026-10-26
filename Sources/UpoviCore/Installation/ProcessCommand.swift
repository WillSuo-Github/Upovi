import Foundation

public final class ProcessCommand: @unchecked Sendable {
    public init() { }
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false
    public func cancel() { lock.withLock { cancelled = true; if process.isRunning { process.terminate() } } }
    public func run(_ executable: String, _ arguments: [String], timeoutSeconds: TimeInterval = 300, outputFile: URL? = nil, environment: [String: String]? = nil, maximumOutputBytes: Int = 20_000_000) async throws -> Data {
        try await withTaskCancellationHandler {
            try await Task.detached { [self] in
                let pipe = Pipe()
                try lock.withLock {
                    if cancelled { throw CancellationError() }
                    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
                    process.environment = environment
                    process.standardOutput = pipe; process.standardError = outputFile == nil ? FileHandle.nullDevice : pipe
                    try process.run()
                }
                let timeout = DispatchWorkItem { [weak self] in self?.cancel() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
                var data = Data(); var overflow = false
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                    if data.count + chunk.count <= maximumOutputBytes { data.append(chunk) }
                    else { overflow = true }
                }
                process.waitUntilExit(); timeout.cancel()
                if let outputFile { try data.write(to: outputFile, options: .atomic) }
                try lock.withLock {
                    if cancelled { throw CancellationError() }
                    guard !overflow else { throw PeerError.unavailable("System tool output exceeded its size limit") }
                    guard process.terminationStatus == 0 else { throw PeerError.unavailable("System tool failed: \(URL(fileURLWithPath: executable).lastPathComponent) (\(process.terminationStatus))") }
                }
                return data
            }.value
        } onCancel: { self.cancel() }
    }
}
