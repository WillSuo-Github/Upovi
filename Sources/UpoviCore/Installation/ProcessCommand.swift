import Foundation

public final class ProcessCommand: @unchecked Sendable {
    public init() { }
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false
    public func cancel() { lock.withLock { cancelled = true; if process.isRunning { process.terminate() } } }
    public func run(_ executable: String, _ arguments: [String], timeoutSeconds: TimeInterval = 300, outputFile: URL? = nil, environment: [String: String]? = nil, maximumOutputBytes: Int = 20_000_000, successCodes: Set<Int32> = [0], currentDirectory: URL? = nil) async throws -> Data {
        let operation = UpoviLogOperation("process.run", category: .process,
            details: "tool=\(URL(fileURLWithPath: executable).lastPathComponent) arguments=\(arguments.count) timeoutSeconds=\(timeoutSeconds) maximumOutputBytes=\(maximumOutputBytes)")
        do {
            let data = try await execute(executable, arguments, timeoutSeconds: timeoutSeconds, outputFile: outputFile, environment: environment,
                maximumOutputBytes: maximumOutputBytes, successCodes: successCodes, currentDirectory: currentDirectory, operation: operation)
            operation.finish(details: "exitStatus=\(process.terminationStatus) outputBytes=\(data.count)")
            return data
        } catch { operation.fail(error); throw error }
    }
    private func execute(_ executable: String, _ arguments: [String], timeoutSeconds: TimeInterval, outputFile: URL?, environment: [String: String]?,
                         maximumOutputBytes: Int, successCodes: Set<Int32>, currentDirectory: URL?, operation: UpoviLogOperation) async throws -> Data {
        try await withTaskCancellationHandler {
            try await Task.detached { [self] in
                let pipe = Pipe()
                try lock.withLock {
                    if cancelled { throw CancellationError() }
                    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
                    process.environment = environment
                    process.currentDirectoryURL = currentDirectory
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = pipe; process.standardError = outputFile == nil ? FileHandle.nullDevice : pipe
                    try process.run()
                }
                let timeout = DispatchWorkItem { [weak self] in operation.event("timeoutFired", level: .warning); self?.cancel() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
                var data = Data(); var overflow = false
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                    if data.count + chunk.count <= maximumOutputBytes { data.append(chunk) }
                    else { overflow = true }
                }
                process.waitUntilExit(); timeout.cancel()
                operation.event("exited", details: "exitStatus=\(process.terminationStatus) reason=\(process.terminationReason.rawValue) outputBytes=\(data.count) overflow=\(overflow)")
                if let outputFile { try data.write(to: outputFile, options: .atomic) }
                try lock.withLock {
                    if cancelled { throw CancellationError() }
                    guard !overflow else { throw PeerError.unavailable("System tool output exceeded its size limit") }
                    guard process.terminationReason == .exit, successCodes.contains(process.terminationStatus) else { throw PeerError.unavailable("System tool failed: \(URL(fileURLWithPath: executable).lastPathComponent) (\(process.terminationStatus))") }
                }
                return data
            }.value
        } onCancel: { self.cancel() }
    }
}
