// Explicit public-HTTPS acceptance. Downloads only the pinned official test archive into .local.
import CryptoKit
import Foundation
import UpoviCore

final class DownloadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, any Error>?
    private var requested = false
    func set(_ value: Task<Void, any Error>) { lock.withLock { task = value; if requested { value.cancel() } } }
    func cancel() { lock.withLock { requested = true; task?.cancel() } }
}
final class ResumeObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: Int64 = 0
    func record(_ value: Int64) { lock.withLock { offset = value } }
    var resumedOffset: Int64 { lock.withLock { offset } }
}

@main struct DownloadResumeAcceptance {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Supply a new private .local output directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard root.path.contains("/.local/"), root.resolvingSymlinksInPath().path == root.path,
              !FileManager.default.fileExists(atPath: root.path) else { fatalError("Use a new unlinked .local output directory") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = DownloadDescriptor(url: URL(string: "https://github.com/rxhanson/Rectangle/releases/download/v2.0.4/Rectangle2.0.4.zip")!,
            sha256: "0b9b8b11edeb3237e3224c619a6f6bfb5e5996a477048be6ff4b98b0346aedc9")
        let app = InstalledApp(name: "Synthetic download fixture", bundleID: "app.upovi.synthetic.resume", version: "1", path: "/synthetic/Fixture.app")
        let directory = root.appending(path: "Cache"), cancel = DownloadCancellation()
        let first = ArtifactDownloadCache(directory: directory)
        let task = Task {
            try await first.download(descriptor, app: app, to: root.appending(path: "cancelled.zip")) { received, _ in
                if received > 0 { cancel.cancel() }
            }
        }
        cancel.set(task)
        do { try await task.value; fatalError("The first transfer unexpectedly completed before cancellation") } catch { }
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent != ".locks" }
        guard entries.count == 1 else { fatalError("Expected exactly one retained download entry") }
        let partial = entries[0].appending(path: "Download.part")
        let bytes = (try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as! NSNumber).int64Value
        guard bytes > 0 else { fatalError("No actual prefix was retained") }
        let observation = ResumeObservation(), restarted = ArtifactDownloadCache(directory: directory)
        let output = root.appending(path: "verified.zip")
        try await restarted.download(descriptor, app: app, to: output, onResume: { observation.record($0) }) { _, _ in }
        guard observation.resumedOffset == bytes else { fatalError("The public server did not complete a validated 206 resume") }
        let actual = try BundleVerifier.sha256(of: output)
        guard actual == descriptor.sha256 else { fatalError("Final archive hash mismatch") }
        let result: [String: Any] = ["publicHTTPS": true, "cancelledOutputAbsent": !FileManager.default.fileExists(atPath: root.appending(path: "cancelled.zip").path),
            "retainedBytes": bytes, "validated206Offset": observation.resumedOffset, "freshCacheInstance": true,
            "sha256": actual, "boundary": "Archive download and integrity acceptance only; no application installed."]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appending(path: "result.json"), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
    }
}
