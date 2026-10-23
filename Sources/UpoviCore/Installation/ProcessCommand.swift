import Foundation

final class ProcessCommand: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true; if process.isRunning { process.terminate() } } }
    func run(_ executable: String, _ arguments: [String]) async throws -> Data {
        try await withTaskCancellationHandler {
            try await Task.detached { [self] in
                let pipe = Pipe()
                try lock.withLock {
                    if cancelled { throw CancellationError() }
                    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
                    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
                    try process.run()
                }
                let timeout = DispatchWorkItem { [weak self] in self?.cancel() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timeout)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); timeout.cancel()
                try lock.withLock {
                    if cancelled { throw CancellationError() }
                    guard process.terminationStatus == 0 else { throw PeerError.unavailable("System tool failed: \(URL(fileURLWithPath: executable).lastPathComponent) (\(process.terminationStatus))") }
                }
                return data
            }.value
        } onCancel: { self.cancel() }
    }
}
