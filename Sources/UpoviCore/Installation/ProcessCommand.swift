import Foundation

public final class ProcessCommand: @unchecked Sendable {
    public init() { }
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false
    private var idleTimedOut = false
    private var lastActivity: DispatchTime?
    public func cancel() { lock.withLock { cancelled = true; if process.isRunning { process.terminate() } } }
    public func run(_ executable: String, _ arguments: [String], timeoutSeconds: TimeInterval? = 300, outputFile: URL? = nil, environment: [String: String]? = nil, maximumOutputBytes: Int = 20_000_000, successCodes: Set<Int32> = [0], currentDirectory: URL? = nil, timeoutActivity: (@Sendable () -> Bool)? = nil) async throws -> Data {
        let timeoutMode = timeoutSeconds == nil ? "delegated" : timeoutActivity == nil ? "fixed" : "inactivity"
        let operation = UpoviLogOperation("process.run", category: .process,
            details: "tool=\(URL(fileURLWithPath: executable).lastPathComponent) arguments=\(arguments.count) timeoutMode=\(timeoutMode) timeoutSeconds=\(timeoutSeconds ?? 0) maximumOutputBytes=\(maximumOutputBytes)")
        do {
            let data = try await execute(executable, arguments, timeoutSeconds: timeoutSeconds, outputFile: outputFile, environment: environment,
                maximumOutputBytes: maximumOutputBytes, successCodes: successCodes, currentDirectory: currentDirectory, timeoutActivity: timeoutActivity, operation: operation)
            operation.finish(details: "exitStatus=\(process.terminationStatus) outputBytes=\(data.count)")
            return data
        } catch { operation.fail(error); throw error }
    }
    private func execute(_ executable: String, _ arguments: [String], timeoutSeconds: TimeInterval?, outputFile: URL?, environment: [String: String]?,
                         maximumOutputBytes: Int, successCodes: Set<Int32>, currentDirectory: URL?, timeoutActivity: (@Sendable () -> Bool)?, operation: UpoviLogOperation) async throws -> Data {
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
                let timeout = timeoutSeconds.map { startTimeout($0, activity: timeoutActivity, operation: operation) }
                defer { timeout?.cancel() }
                var data = Data(); var overflow = false
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                    if data.count + chunk.count <= maximumOutputBytes { data.append(chunk) }
                    else { overflow = true }
                }
                process.waitUntilExit(); timeout?.cancel()
                operation.event("exited", details: "exitStatus=\(process.terminationStatus) reason=\(process.terminationReason.rawValue) outputBytes=\(data.count) overflow=\(overflow)")
                if let outputFile { try data.write(to: outputFile, options: .atomic) }
                try lock.withLock {
                    if cancelled { throw CancellationError() }
                    if idleTimedOut { throw URLError(.timedOut) }
                    guard !overflow else { throw PeerError.unavailable("System tool output exceeded its size limit") }
                    guard process.terminationReason == .exit, successCodes.contains(process.terminationStatus) else { throw PeerError.unavailable("System tool failed: \(URL(fileURLWithPath: executable).lastPathComponent) (\(process.terminationStatus))") }
                }
                return data
            }.value
        } onCancel: { self.cancel() }
    }

    private func startTimeout(_ seconds: TimeInterval, activity: (@Sendable () -> Bool)?, operation: UpoviLogOperation) -> DispatchSourceTimer {
        let started = DispatchTime.now()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        if activity != nil, seconds > 0 {
            let interval = min(60, seconds / 4)
            timer.schedule(deadline: started + interval, repeating: interval)
        } else {
            timer.schedule(deadline: started + seconds)
        }
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let advanced = activity?() == true
            lock.withLock {
                guard process.isRunning, !cancelled, !idleTimedOut else { return }
                let now = DispatchTime.now()
                if advanced {
                    if lastActivity == nil { operation.event("activityObserved") }
                    lastActivity = now
                }
                guard activity == nil || now >= (lastActivity ?? started) + seconds else { return }
                operation.event("timeoutFired", level: .warning)
                if activity == nil { cancelled = true } else { idleTimedOut = true }
                process.terminate()
            }
        }
        timer.activate()
        return timer
    }
}
