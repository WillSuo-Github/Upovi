import Foundation

/// A single user-exported ZIP keeps the current snapshot and retained timeline together.
public enum DiagnosticArchive {
    public struct Environment: Sendable {
        public let version: String, build: String, sourceRevision: String
        public init(version: String, build: String, sourceRevision: String) {
            self.version = version; self.build = build; self.sourceRevision = sourceRevision
        }
    }
    public static func prepare(report: Data, includeLogs: Bool, environment: Environment,
                               manager: UpoviLogManager = .shared) async throws -> Data {
        guard report.count <= 2_000_000, (try JSONSerialization.jsonObject(with: report)) is [String: Any] else {
            throw PeerError.invalid("Invalid diagnostics snapshot")
        }
        let operation = UpoviLogOperation("diagnostics.export", category: .diagnostics, details: "includeLogs=\(includeLogs)", manager: manager)
        do {
            let work = Task.detached(priority: .utility) {
                let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "Upovi-diagnostics-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: root) }
                let folder = root.appending(path: "Upovi-Diagnostics")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                func write(_ data: Data, _ name: String) throws {
                    let file = folder.appending(path: name)
                    try data.write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                }
                try write(report, "snapshot.json")
                let logs = includeLogs ? try manager.exportSnapshot() : "Runtime logs were excluded by the user.\n"
                try write(Data(logs.utf8), "runtime.log")
                let process = ProcessInfo.processInfo
                let manifest: [String: Any] = [
                    "schemaVersion": 1, "exportedAt": Date().ISO8601Format(), "sessionID": manager.sessionID,
                    "version": UpoviLogPrivacy.sanitize(environment.version), "build": UpoviLogPrivacy.sanitize(environment.build),
                    "sourceRevision": UpoviLogPrivacy.sanitize(environment.sourceRevision),
                    "system": process.operatingSystemVersionString, "systemUptimeSeconds": Int(process.systemUptime),
                    "architecture": architecture, "locale": Locale.current.identifier, "timeZone": TimeZone.current.identifier,
                    "includesRuntimeLogs": includeLogs, "automaticallyUploaded": false,
                    "maximumRetentionDays": 14, "maximumFileBytes": 5 * 1024 * 1024, "maximumTotalLogBytes": 40 * 1024 * 1024
                ]
                try write(try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]), "manifest.json")
                try write(Data("""
                Upovi diagnostic bundle
                - manifest.json: app/build, source revision, session and environment.
                - snapshot.json: current source checks, error classifications and recent transactions.
                - runtime.log: retained sessions, paired operation IDs, durations, transitions and bounded error chains.
                Match snapshot logReference to app= in runtime.log; request/parent connects concurrent work.
                Timestamps are UTC. Versions and error details can reveal software context; review before sharing.
                Paths, URL credentials, signed queries and recognizable secrets are filtered. No request/response bodies,
                shell commands, environment values or raw system/administrator logs are collected. Filtering cannot
                recognize arbitrary user content; avoid sending secrets in a bug report.
                Retention is bounded by 14 days, 5 MiB per file, 40 MiB total and 200 files, oldest removed first.
                A busy writer reports dropped entries and file IO failures. Force kills can lose pending entries.
                No automatic upload occurs. Include the approximate problem time and reproduction steps with feedback.
                """.utf8), "README.txt")
                try Task.checkCancellation()
                let archive = root.appending(path: "Upovi-Diagnostics.zip")
                _ = try await ProcessCommand().run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", "--keepParent", folder.path, archive.path], timeoutSeconds: 120, maximumOutputBytes: 65536)
                try Task.checkCancellation()
                let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 50 * 1024 * 1024 else { throw PeerError.invalid("Diagnostic archive exceeds its size limit") }
                return try Data(contentsOf: archive)
            }
            let data = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            operation.finish(details: "archiveBytes=\(data.count)")
            return data
        } catch { operation.fail(error); throw error }
    }
    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
