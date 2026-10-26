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

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Upovi/AdministratorAttempts")) { self.directory = directory; refresh() }
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
            try await ArtifactDownloadCache.shared.download(descriptor, app: app, to: package, progress: progress)
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

    func perform(_ plan: AdministratorInstallPlan) async throws {
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
            let script = try AdministratorAuthorization.script(helper: helper, plan: input, hostTeam: team)
            let data = try await ProcessCommand().run("/usr/bin/osascript", ["-e", script], timeoutSeconds: 2100,
                outputFile: directory.appending(path: plan.id.uuidString + "-authorization.log"))
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
