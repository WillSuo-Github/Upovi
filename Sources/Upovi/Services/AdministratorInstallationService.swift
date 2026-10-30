import Foundation
import Observation
import UpoviCore

struct PreparedInstallerPackage {
    let plan: AdministratorInstallPlan
    let workspace: URL
}

@MainActor @Observable
final class AdministratorInstallationService {
    private(set) var attempts: [AdministratorInstallAttempt] = []
    private let directory: URL
    private let downloads: DownloadCoordinator

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Upovi/AdministratorAttempts"), downloads: DownloadCoordinator = .shared) { self.directory = directory; self.downloads = downloads; refresh() }
    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        attempts = files.filter { $0.pathExtension == "json" }.compactMap {
            guard (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max < 65536,
                  let data = try? Data(contentsOf: $0) else { return nil }
            return try? JSONDecoder().decode(AdministratorInstallAttempt.self, from: data)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    private func save(_ attempt: AdministratorInstallAttempt) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appending(path: attempt.id.uuidString + ".json")
        try JSONEncoder().encode(attempt).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        refresh()
    }

    func preparePackage(_ candidate: UpdateCandidate, app: InstalledApp,
                        progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> PreparedInstallerPackage {
        guard !candidate.isCommunity, !app.isAppStore, let descriptor = candidate.download,
              descriptor.hasIntegrityProof, descriptor.url.pathExtension.lowercased() == "pkg" else { throw PeerError.invalid("No verified package download") }
        let workspace = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "Upovi-package-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let package = workspace.appending(path: "Update.pkg")
            try await downloads.download(descriptor, app: app, targetVersion: candidate.version, to: package, progress: progress)
            let hash = try await Task.detached {
                try BundleVerifier.verifyArchive(package, descriptor: descriptor, app: app)
                return try BundleVerifier.sha256(of: package)
            }.value
            try await InstallerPackageVerifier.validate(package, sha256: hash, app: app)
            let plan = AdministratorInstallPlan(operation: .package, application: app, version: candidate.version,
                                                build: candidate.build, artifactPath: package.path, sha256: hash)
            try plan.validate()
            try Task.checkCancellation()
            return .init(plan: plan, workspace: workspace)
        } catch { try? FileManager.default.removeItem(at: workspace); throw error }
    }
    func discard(_ prepared: PreparedInstallerPackage) { try? FileManager.default.removeItem(at: prepared.workspace) }

    func perform(_ plan: AdministratorInstallPlan, authorize: InstallationAuthorization = .system) async throws {
        try plan.validate()
        guard let team = AdministratorAuthorization.teamID(at: Bundle.main.bundleURL),
              let helper = Bundle.main.url(forAuxiliaryExecutable: "UpoviInstaller") else {
            throw PeerError.unavailable("Use a complete Developer ID signed Upovi bundle for administrator installation")
        }
        if ![.discardBackup, .inspect].contains(plan.operation) { try await UpdateInstaller.requestApplicationQuit(plan.application) }
        var attempt = AdministratorInstallAttempt(plan: plan, state: "awaitingAuthorization")
        let installing = [.application, .package].contains(plan.operation)
        if installing { try save(attempt) }
        if plan.operation == .discardBackup, var cached = attempts.first(where: { $0.id == plan.id }) {
            cached.state = "cleanupPending"; try save(cached)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let input = directory.appending(path: "Request-\(UUID().uuidString).json")
        try JSONEncoder().encode(plan).write(to: input, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        defer { try? FileManager.default.removeItem(at: input) }
        do {
            let command = try AdministratorAuthorization.command(helper: helper, plan: input, hostTeam: team)
            let data = try await authorize.run(command, directory.appending(path: plan.id.uuidString + "-authorization.log"))
            let result = try JSONDecoder().decode(AdministratorInstallAttempt.self, from: data)
            let accepted = plan.operation == .inspect || (plan.operation == .discardBackup ? result.state == "backupDiscarded" : plan.operation == .restore ? result.state == "restored" : result.state == "installed")
            guard result.id == plan.id, accepted else { throw PeerError.invalid("Unexpected administrator transaction result") }
            try save(result)
        } catch {
            if installing {
                attempt.state = "interruptedOrFailed"; attempt.updatedAt = Date(); try? save(attempt)
            }
            throw error
        }
    }
}

/// An authorization boundary shared by direct and App Store installations.
struct InstallationAuthorization: Sendable {
    let run: @MainActor @Sendable (String, URL?) async throws -> Data
    static let system = Self { command, log in
        try await ProcessCommand().run("/usr/bin/osascript", ["-e", AdministratorAuthorization.script(command: command)],
            timeoutSeconds: 2100, outputFile: log)
    }
}

/// Downloads finish before the pending privileged commands are submitted together.
/// Only this batch's signed-helper commands run, in order, under one system prompt.
@MainActor
final class InstallationAuthorizationBatch {
    struct Job: Sendable {
        let item: BulkUpdateItem
        let operation: @MainActor @Sendable (InstallationAuthorization) async throws -> Void
        let cleanup: @MainActor @Sendable () async -> Void
    }
    private(set) var jobs: [Job] = []
    private var arrived = Set<String>()
    private var requests: [String: (String, URL?, CheckedContinuation<Data, any Error>)] = [:]
    private var execution: Task<Void, Never>?
    private var stopped = false
    private let stopFile = FileManager.default.temporaryDirectory.appending(path: "Upovi-stop-\(UUID().uuidString)")
    private let execute: @MainActor @Sendable (String, Int) async throws -> Data

    init(execute: @escaping @MainActor @Sendable (String, Int) async throws -> Data = { command, count in
        try await ProcessCommand().run("/usr/bin/osascript", ["-e", AdministratorAuthorization.script(command: command)],
            timeoutSeconds: TimeInterval(2100 * count), maximumOutputBytes: max(65536, count * 100000))
    }) { self.execute = execute }

    func enqueue(_ item: BulkUpdateItem, cleanup: @escaping @MainActor @Sendable () async -> Void = {},
                 operation: @escaping @MainActor @Sendable (InstallationAuthorization) async throws -> Void) {
        jobs.append(.init(item: item, operation: operation, cleanup: cleanup))
    }
    func contains(_ id: String) -> Bool { jobs.contains { $0.item.id == id } }
    func stop() {
        stopped = true
        // The privileged shell reads only this marker's existence; it never executes its contents.
        try? Data().write(to: stopFile, options: .atomic)
    }
    func authorization(for id: String) -> InstallationAuthorization {
        .init { [self] command, log in
            guard !stopped else { throw CancellationError() }
            return try await withCheckedThrowingContinuation { continuation in
                requests[id] = (command, log, continuation)
                finishRegistration(id)
            }
        }
    }
    /// Also called when preflight failed or the user stopped before submitting a command.
    func finishRegistration(_ id: String) {
        arrived.insert(id)
        guard arrived.count == jobs.count, execution == nil else { return }
        execution = Task { [self] in
            defer { try? FileManager.default.removeItem(at: stopFile) }
            let ordered = jobs.compactMap { requests[$0.item.id] }
            guard !ordered.isEmpty else { return }
            do {
                if stopped { throw CancellationError() }
                let command = AdministratorAuthorization.batchCommand(ordered.map { $0.0 }, stopFile: stopFile)
                let data = try await execute(command, ordered.count)
                let results = try AdministratorAuthorization.batchResults(data, count: ordered.count)
                for (request, result) in zip(ordered, results) {
                    if let log = request.1 { try? result.output.write(to: log, options: .atomic) }
                    if result.status == 0 { request.2.resume(returning: result.output) }
                    else if result.status == -1 { request.2.resume(throwing: CancellationError()) }
                    else { request.2.resume(throwing: PeerError.unavailable("Authorized installer failed (\(result.status)): \(String(decoding: result.output.prefix(4096), as: UTF8.self))")) }
                }
            } catch {
                for request in ordered { request.2.resume(throwing: error) }
            }
            requests = [:]
        }
    }
}
