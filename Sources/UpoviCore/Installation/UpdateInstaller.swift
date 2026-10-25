import Foundation
import AppKit
import Darwin

public struct PreparedUpdate: Identifiable, Sendable {
    public let id: UUID
    public let application: InstalledApp
    public let replacement: InstalledApp
    public let workspace: URL
    public let bundle: URL
}

public actor UpdateInstaller {
    public static let defaultJournalDirectory = URL.applicationSupportDirectory.appending(path: "Upovi/Installations")
    private let journalDirectory: URL
    private var busy = false
    private var prepared: PreparedUpdate?
    public init(journalDirectory: URL = UpdateInstaller.defaultJournalDirectory) { self.journalDirectory = journalDirectory }

    public func prepare(app: InstalledApp, candidate: UpdateCandidate,
                        progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> PreparedUpdate {
        guard !busy else { throw PeerError.unavailable("An installation operation is already running") }
        guard !candidate.isCommunity, !app.isAppStore, let descriptor = candidate.download, descriptor.hasIntegrityProof,
              let team = app.teamID, !team.isEmpty, app.bundleID != "app.upovi.Upovi" else {
            throw PeerError.invalid("Use the official source or in-app updater for this application")
        }
        busy = true; defer { busy = false }
        if let prepared { try? FileManager.default.removeItem(at: prepared.workspace); self.prepared = nil }
        let workspace = FileManager.default.temporaryDirectory.appending(path: "Upovi-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let archive = workspace.appending(path: "update." + descriptor.url.pathExtension.lowercased())
        do {
            try await HTTPTransfer.download(from: descriptor.url, to: archive, progress: progress)
            let verification = Task.detached { try BundleVerifier.verifyArchive(archive, descriptor: descriptor, app: app) }
            try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
            try Task.checkCancellation()
            let extracted: URL
            var mounted: URL?
            if archive.pathExtension == "zip" {
                extracted = workspace.appending(path: "Extracted")
                let extraction = Task.detached { try ArchiveExtractor.extractZIP(archive, to: extracted) }
                try await withTaskCancellationHandler { try await extraction.value } onCancel: { extraction.cancel() }
            } else if archive.pathExtension == "dmg" {
                extracted = workspace.appending(path: "Mounted")
                try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
                _ = try await ProcessCommand().run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", extracted.path, archive.path])
                mounted = extracted
            } else { throw PeerError.invalid("Only signed ZIP and DMG application updates are supported") }
            do {
                try Task.checkCancellation()
                let matches = Self.bundles(in: extracted).filter { AppScanner.read($0)?.bundleID == app.bundleID }
                guard matches.count == 1, let source = matches.first else { throw PeerError.invalid("Archive does not contain exactly one matching application") }
                let staged = workspace.appending(path: "Prepared.app")
                try FileManager.default.copyItem(at: source, to: staged)
                if let mounted { _ = try await ProcessCommand().run("/usr/bin/hdiutil", ["detach", mounted.path]) }
                let replacement = try BundleVerifier.validate(staged, replacing: app, expectedVersion: candidate.version, expectedBuild: candidate.build)
                if let executable = Bundle(url: staged)?.executableURL { try MachOCompatibility.validate(executable) }
                else { throw PeerError.invalid("Update has no application executable") }
                // Preserve the normal macOS trust boundary; never remove quarantine or bypass Gatekeeper.
                let quarantine = "0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));Upovi;\(UUID().uuidString)"
                let status = quarantine.withCString { pointer in
                    setxattr(staged.path, "com.apple.quarantine", pointer, strlen(pointer), 0, 0)
                }
                guard status == 0 else { throw PeerError.unavailable("Cannot quarantine the downloaded application") }
                _ = try await ProcessCommand().run("/usr/sbin/spctl", ["--assess", "--type", "execute", staged.path])
                let value = PreparedUpdate(id: UUID(), application: app, replacement: replacement, workspace: workspace, bundle: staged)
                prepared = value; return value
            } catch {
                if let mounted { _ = try? await ProcessCommand().run("/usr/bin/hdiutil", ["detach", mounted.path]) }
                throw error
            }
        } catch { try? FileManager.default.removeItem(at: workspace); throw error }
    }

    public func discard(_ id: UUID) {
        guard !busy, let prepared, prepared.id == id else { return }
        try? FileManager.default.removeItem(at: prepared.workspace); self.prepared = nil
    }

    public func install(_ id: UUID) async throws -> InstallationReceipt {
        guard !busy, let value = prepared, value.id == id else { throw PeerError.invalid("Prepared update is no longer available") }
        busy = true; defer { busy = false }
        try await Self.quit(value.application)
        try Task.checkCancellation()
        // Once the rename transaction starts it runs to completion or recovery, even if the UI task is cancelled.
        let journal = journalDirectory
        let receipt = try await Task.detached {
            try BundleTransaction(journalDirectory: journal, validate: { url in
                _ = try BundleVerifier.validate(url, replacing: value.application,
                    expectedVersion: value.replacement.version, expectedBuild: value.replacement.build)
            }).commit(prepared: value.bundle, replacing: value.application,
                      newVersion: value.replacement.version, newBuild: value.replacement.build)
        }.value
        try? FileManager.default.removeItem(at: value.workspace); prepared = nil
        return receipt
    }

    public func receipts() throws -> [InstallationReceipt] {
        let files = (try? FileManager.default.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max < 100_000,
                  let data = try? Data(contentsOf: url), let receipt = try? JSONDecoder().decode(InstallationReceipt.self, from: data),
                  UUID(uuidString: receipt.id) != nil else { return nil }
            return receipt
        }.sorted { $0.date > $1.date }
    }

    public func restore(_ receipt: InstallationReceipt) async throws {
        guard !busy else { throw PeerError.unavailable("An installation operation is already running") }
        busy = true; defer { busy = false }
        try await Self.quit(receipt.application)
        try BundleVerifier.checkSignature(URL(fileURLWithPath: receipt.backupPath), like: receipt.application)
        let journal = journalDirectory
        _ = try await Task.detached {
            try BundleTransaction(journalDirectory: journal, validate: { _ in }).restore(receipt)
        }.value
    }
    public static func requestApplicationQuit(_ app: InstalledApp) async throws { try await quit(app) }

    public func discardBackup(_ receipt: InstallationReceipt) async throws {
        guard !busy else { throw PeerError.unavailable("An installation operation is already running") }
        busy = true; defer { busy = false }
        guard let retainedPath = receipt.retainedPath else { throw PeerError.invalid("Keep interrupted installation backups for recovery") }
        let backup = URL(fileURLWithPath: retainedPath)
        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL.path == backup.path }
        }
        guard !running else { throw PeerError.invalid("Quit the backup application before moving it to Trash") }
        let journal = journalDirectory
        _ = try await Task.detached {
            try BundleTransaction(journalDirectory: journal, validate: { _ in }).discardBackup(receipt) { url in
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }.value
    }

    private static func quit(_ app: InstalledApp) async throws {
        func running() async -> Bool {
            await MainActor.run { NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL.path == app.path } }
        }
        await MainActor.run {
            for application in NSWorkspace.shared.runningApplications where application.bundleURL?.standardizedFileURL.path == app.path {
                _ = application.terminate()
            }
        }
        for _ in 0..<40 {
            if !(await running()) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw PeerError.unavailable("Close the application and save its documents before installing")
    }
    private static func bundles(in root: URL) -> [URL] {
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [URL] = [], count = 0
        for case let url as URL in iterator {
            count += 1; if count > 10000 { break }
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { iterator.skipDescendants(); continue }
            if url.pathExtension.lowercased() == "app" { result.append(url); iterator.skipDescendants() }
        }
        return result
    }
}
