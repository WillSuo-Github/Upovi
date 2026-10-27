// Real official downloads and isolated app copies only. No system components are installed.
import AppKit
import Foundation
import UpoviCore

@main
struct SourceInstallationAcceptance {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("Acceptance failed: \(error.localizedDescription)\n".utf8)); exit(1) }
    }

    static func run() async throws {
        let arguments = CommandLine.arguments
        func option(_ key: String) throws -> String {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else {
                throw PeerError.invalid("Missing \(key)")
            }
            return arguments[index + 1]
        }
        let root = URL(fileURLWithPath: try option("--root")).standardizedFileURL
        let path = URL(fileURLWithPath: try option("--app")).standardizedFileURL
        guard root.path.contains("/.local/"), root.resolvingSymlinksInPath().path == root.path,
              path.deletingLastPathComponent().path == root.appending(path: "Applications").path, path.pathExtension == "app",
              let app = AppScanner.read(path) else { throw PeerError.invalid("Use a signed isolated copy under the acceptance root/Applications") }
        let center = DownloadCoordinator(cache: ArtifactDownloadCache(directory: root.appending(path: "Cache")),
                                         storageURL: root.appending(path: "downloads.json"))
        let installer = UpdateInstaller(journalDirectory: root.appending(path: "Journal"), downloads: center)
        let evidencePath = root.appending(path: app.bundleID + "-result.json")
        var evidence: [String: Any] = ["bundleID": app.bundleID, "path": path.path, "isolatedCopiesOnly": true,
                                       "systemComponentsTested": false, "originalVersion": app.version, "originalBuild": app.build]
        func save() throws {
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: evidencePath, options: .atomic)
        }
        if arguments.contains("--restore-only") {
            guard let receipt = try await installer.receipts().first(where: { $0.application.path == app.path && $0.state == .installed }) else {
                throw PeerError.invalid("No isolated installed receipt to restore")
            }
            try await installer.restore(receipt)
            guard let restored = AppScanner.read(path), restored.version == receipt.application.version,
                  restored.build == receipt.application.build else { throw PeerError.invalid("Restored version mismatch") }
            try BundleVerifier.checkSignature(path, like: receipt.application)
            if let data = try? Data(contentsOf: evidencePath), let prior = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { evidence = prior }
            evidence["restoredVersion"] = restored.version; evidence["restoredBuild"] = restored.build
            evidence["restorePassed"] = true; try save()
            print("Restored \(app.name): \(restored.version) (\(restored.build))"); return
        }
        try BundleVerifier.checkSignature(path, like: app)
        if arguments.contains("--verify-identity") {
            print("Verified official identity: \(app.bundleID) \(app.version) (\(app.build))")
            return
        }
        evidence["legacyOfficialIdentityVerified"] = ApplicationSourceCatalog.legacyMigration(for: app) != nil
        evidence["originalTeamID"] = app.teamID ?? "not set"
        let result = await UpdateChecker.check(app)
        evidence["sourceStatus"] = result.status.rawValue
        evidence["sourceNote"] = result.note
        evidence["candidates"] = result.candidates.map { candidate -> [String: Any] in
            ["source": candidate.source, "version": candidate.version, "build": candidate.build,
             "download": candidate.download?.url.absoluteString ?? "", "archiveProof": candidate.download?.hasIntegrityProof ?? false]
        }
        try save()
        guard let item = BulkUpdatePlan.make(apps: [app], results: [app.id: result], ignored: []).first, item.canInstall else {
            throw PeerError.invalid("Live sources did not produce an installable update: \(result.note)")
        }
        print("Preparing \(app.name): \(app.version) -> \(item.candidate.version) via \(item.candidate.source)")
        do {
            let prepared = try await installer.prepare(app: app, candidate: item.candidate, progress: { _, _ in })
            evidence["archiveIntegrityVerified"] = prepared.archiveIntegrityVerified
            evidence["preparedVersion"] = prepared.replacement.version
            evidence["preparedBuild"] = prepared.replacement.build
            evidence["gatekeeperPassed"] = true
            let receipt = try await installer.install(prepared.id)
            guard let installed = AppScanner.read(path), installed.version == prepared.replacement.version,
                  installed.build == prepared.replacement.build else { throw PeerError.invalid("Installed version mismatch") }
            try BundleVerifier.checkDeveloperIDSignature(path, like: app)
            evidence["installedVersion"] = installed.version; evidence["installedBuild"] = installed.build
            evidence["developerIDPassed"] = true; evidence["backupRetained"] = FileManager.default.fileExists(atPath: receipt.backupPath)
            evidence["installationPassed"] = true
            let records = await center.snapshot()
            evidence["downloadVerified"] = records.first?.state == .verified
            let refreshed = await UpdateChecker.check(installed)
            let remaining = BulkUpdatePlan.make(apps: [installed], results: [installed.id: refreshed], ignored: [])
            evidence["postInstallSourceStatus"] = refreshed.status.rawValue
            evidence["postInstallUpdateCount"] = remaining.count
            guard remaining.isEmpty, refreshed.status == .current ||
                    (refreshed.status == .partial && refreshed.checks.contains(where: { $0.outcome == .checked })) else { throw PeerError.invalid("Live sources did not confirm the installed app is current") }
            try save()
            print("Installed \(app.name): \(installed.version) (\(installed.build)); backup retained")
        } catch {
            evidence["installationPassed"] = false; evidence["failure"] = error.localizedDescription
            try save(); throw error
        }
    }
}
