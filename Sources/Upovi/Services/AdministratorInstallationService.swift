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
        guard !candidate.isCommunity, candidate.requiresRevalidation != true, app.bundleID != "com.valvesoftware.steam", !app.isAppStore, let descriptor = candidate.download,
              descriptor.hasIntegrityProof, descriptor.url.pathExtension.lowercased() == "pkg" else { throw PeerError.invalid("No verified package download") }
        try await Task.detached { try AdministratorInstallationSpace.validate(application: URL(fileURLWithPath: app.path)) }.value
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
                                                build: candidate.build, artifactPath: package.path, sha256: hash, permitsPrerelease: candidate.releaseChannel == .beta)
            try plan.validate()
            try Task.checkCancellation()
            return .init(plan: plan, workspace: workspace)
        } catch { try? FileManager.default.removeItem(at: workspace); throw error }
    }
    func discard(_ prepared: PreparedInstallerPackage) { try? FileManager.default.removeItem(at: prepared.workspace) }

    func perform(_ plan: AdministratorInstallPlan, authorize: InstallationAuthorization = .system) async throws {
        try plan.validate()
        if [.application, .package].contains(plan.operation) {
            try await Task.detached { try AdministratorInstallationSpace.validate(application: URL(fileURLWithPath: plan.application.path)) }.value
        }
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
            let data = try await authorize.perform(.application(plan), command: command, log: directory.appending(path: plan.id.uuidString + "-authorization.log"))
            let result = try JSONDecoder().decode(AdministratorInstallAttempt.self, from: data)
            let accepted = plan.operation == .inspect || (plan.operation == .discardBackup ? result.state == "backupDiscarded" : plan.operation == .restore ? result.state == "restored" : ["installed", "finalizationPending"].contains(result.state))
            guard result.id == plan.id, accepted else { throw PeerError.invalid("Unexpected administrator transaction result") }
            try save(result)
            if installing, result.state == "finalizationPending" {
                throw result.finalizationFailure ?? AdministratorFinalizationError(PeerError.unavailable("Installation finalization did not complete"))
            }
        } catch let error as AdministratorFinalizationError { throw error }
        catch {
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
    private let submit: (@MainActor @Sendable (AdministratorInstallSession.Request, URL?) async throws -> Data)?
    init(run: @escaping @MainActor @Sendable (String, URL?) async throws -> Data) {
        self.run = run; submit = nil
    }
    init(submit: @escaping @MainActor @Sendable (AdministratorInstallSession.Request, URL?) async throws -> Data) {
        self.submit = submit
        run = { _, _ in throw PeerError.invalid("A batch authorization accepts only typed installation plans") }
    }
    func perform(_ request: AdministratorInstallSession.Request, command: String, log: URL?) async throws -> Data {
        if let submit { return try await submit(request, log) }
        return try await run(command, log)
    }
    static let system = Self(run: { command, log in
        try await ProcessCommand().run("/usr/bin/osascript", ["-e", AdministratorAuthorization.script(command: command)],
            timeoutSeconds: 2100, outputFile: log)
    })
}

/// One upfront authorization and live submissions as each unprivileged download finishes.
@MainActor
final class InstallationAuthorizationBatch {
    struct Job: Sendable {
        let item: BulkUpdateItem
        let operation: @MainActor @Sendable (InstallationAuthorization) async throws -> Void
        let cleanup: @MainActor @Sendable () async -> Void
    }
    private var tasks: [Task<Void, Never>] = []
    private var registered = Set<String>()
    private var session: AdministratorInstallSession?
    private var execution: Task<Void, Never>?
    private var executionError: (any Error)?
    private var executionFinished = false
    private var stopped = false
    private var ready = false
    private var submitted = Set<Int>()
    private let requests = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "Upovi-session-\(UUID().uuidString)")
    private let startOverride: (@MainActor @Sendable ([BulkUpdateItem]) async throws -> Void)?
    private let submitOverride: (@MainActor @Sendable (AdministratorInstallSession.Request) async throws -> Data)?

    init(start: (@MainActor @Sendable ([BulkUpdateItem]) async throws -> Void)? = nil,
         submit: (@MainActor @Sendable (AdministratorInstallSession.Request) async throws -> Data)? = nil) {
        startOverride = start; submitOverride = submit
    }

    func start(_ items: [BulkUpdateItem]) async throws {
        guard !items.isEmpty else { return }
        if let startOverride { try await startOverride(items); return }
        guard let team = AdministratorAuthorization.teamID(at: Bundle.main.bundleURL),
              let helper = Bundle.main.url(forAuxiliaryExecutable: "UpoviInstaller") else {
            throw PeerError.unavailable("Use a complete Developer ID signed Upovi bundle for administrator installation")
        }
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let session = AdministratorInstallSession(items: items, requests: requests, hostTeam: team)
        try session.validate()
        self.session = session
        let command = try session.bootstrap(helper: helper,
            storeHelper: Bundle.main.bundleURL.appending(path: "Contents/Helpers/UpoviStoreInstaller.app"),
            bridge: Bundle.main.bundleURL.appending(path: "Contents/MacOS/UpoviStoreBridge"))
        execution = Task { [self] in
            do {
                _ = try await ProcessCommand().run("/usr/bin/osascript", ["-e", AdministratorAuthorization.script(command: command)],
                    timeoutSeconds: 6 * 3600 + 2100, outputFile: requests.appending(path: "session.log"), maximumOutputBytes: 65536)
            } catch {
                let log = (try? String(contentsOf: requests.appending(path: "session.log"), encoding: .utf8)) ?? ""
                executionError = log.contains("(-128)") ? CancellationError() : error
            }
            executionFinished = true
        }
        while true {
            try checkExecution()
            if let attrs = try? FileManager.default.attributesOfItem(atPath: session.results.path),
               (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
               ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0,
               FileManager.default.fileExists(atPath: session.results.appending(path: "ready").path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        ready = true
        if stopped { throw CancellationError() }
    }

    func enqueue(_ item: BulkUpdateItem, cleanup: @escaping @MainActor @Sendable () async -> Void = {},
                 operation: @escaping @MainActor @Sendable (InstallationAuthorization) async throws -> Void,
                 run: @escaping @MainActor @Sendable (Job) async -> Void) {
        registered.insert(item.id)
        let job = Job(item: item, operation: operation, cleanup: cleanup)
        tasks.append(Task { await run(job) })
    }
    func contains(_ id: String) -> Bool { registered.contains(id) }
    func stop() {
        stopped = true
        if !ready { execution?.cancel() }
        try? Data().write(to: requests.appending(path: "stop"), options: .atomic)
    }
    func authorization(for id: String) -> InstallationAuthorization {
        .init(submit: { [self] request, log in
            guard !stopped else { throw CancellationError() }
            let output: Data
            if let submitOverride { output = try await submitOverride(request) }
            else {
                guard let session, let index = session.items.firstIndex(where: { $0.id == id }), !submitted.contains(index) else {
                    throw PeerError.invalid("Installation has no active batch authorization")
                }
                try session.validate(request, index: index)
                submitted.insert(index)
                try JSONEncoder().encode(request).write(to: requests.appending(path: "\(index).json"), options: .atomic)
                while true {
                    try checkExecution()
                    if let data = try? Data(contentsOf: session.results.appending(path: "\(index).json")),
                       let result = try? JSONDecoder().decode(AdministratorInstallSession.Result.self, from: data) {
                        if let log { try? result.output.write(to: log, options: .atomic) }
                        if result.status == -1 { throw CancellationError() }
                        guard result.status == 0 else {
                            throw PeerError.unavailable("Authorized installer failed: \(String(decoding: result.output.prefix(4096), as: UTF8.self))")
                        }
                        output = result.output; break
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            if let log { try? output.write(to: log, options: .atomic) }
            return output
        })
    }
    private func checkExecution() throws {
        if let executionError { throw executionError }
        if executionFinished { throw PeerError.unavailable("Installation authorization session ended") }
    }
    func finish() async {
        for task in tasks { await task.value }
        if session != nil { try? Data().write(to: requests.appending(path: "finish"), options: .atomic) }
        await execution?.value
        tasks = []; execution = nil
        try? FileManager.default.removeItem(at: requests)
    }
}
