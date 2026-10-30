import Darwin
import Foundation
import OSLog
import UpoviCore

@MainActor final class AppStoreInstallationService {
    private let directory: URL
    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Upovi/StoreAttempts")) { self.directory = directory }
    static func recoveryItem(for app: InstalledApp, directory: URL = URL.applicationSupportDirectory.appending(path: "Upovi/StoreAttempts")) -> BulkUpdateItem? {
        guard !app.isAppStore else { return nil }
        let logger = Logger(subsystem: "app.upovi.Upovi", category: "store-recovery")
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasSuffix("-authorization.log") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for file in files.prefix(50) {
            guard ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max) < 65536,
                  let data = try? Data(contentsOf: file), let receipt = try? JSONDecoder().decode(AppStoreUpdateReceipt.self, from: data),
                  receipt.plan.application.bundleID == app.bundleID else { continue }
            guard receipt.plan.application.path == app.path,
                  receipt.plan.application.teamID == app.teamID, receipt.plan.application.isAppStore,
                  VersionOrder.compare(app.version, receipt.plan.version) == .orderedSame,
                  let path = receipt.failure?.recoverableReceiptPath(application: app) else {
                logger.error("Store receipt recovery target does not match the recorded failure for \(app.bundleID, privacy: .public)")
                continue
            }
            guard let canonical = try? CanonicalFilePath.resolve(URL(fileURLWithPath: path)) else { continue }
            // The receipt belongs to the download component's protected temporary data. The UI
            // only proposes recovery; the installer checks its root journal and Apple's CMS signature.
            let recovery = StoreReceiptRecovery(transactionID: receipt.plan.id, path: canonical)
            do { try recovery.validate() }
            catch {
                logger.error("Store receipt recovery path validation failed for \(app.bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            var candidate = UpdateCandidate(version: receipt.plan.version, source: "App Store", isCommunity: false, url: nil,
                releaseNotes: String(localized: "主程序已更新，本次只校验并补齐原始商店购买凭据，不会重新下载应用。"), appStoreID: receipt.plan.storeID)
            candidate.storeReceiptRecovery = recovery
            return .init(application: receipt.plan.application, candidate: candidate, manualReason: nil)
        }
        return nil
    }

    func perform(_ candidate: UpdateCandidate, app: InstalledApp, authorize: InstallationAuthorization = .system) async throws {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/UpoviStoreInstaller.app")
        guard !candidate.isCommunity, let id = candidate.appStoreID,
              FileManager.default.fileExists(atPath: helper.appending(path: "Contents/MacOS/UpoviStoreInstaller").path),
              let bridge = Bundle.main.url(forAuxiliaryExecutable: "UpoviStoreBridge"),
              let team = AdministratorAuthorization.teamID(at: Bundle.main.bundleURL) else {
            throw PeerError.unavailable(String(localized: "请使用包含商店更新组件的 Developer ID 签名 Upovi 应用包。"))
        }
        let plan = AppStoreUpdatePlan(application: app, storeID: id, version: candidate.version, userID: getuid(), receiptRecovery: candidate.storeReceiptRecovery)
        try plan.validate()
        try await UpdateInstaller.requestApplicationQuit(app)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let request = directory.appending(path: "Request-\(plan.id.uuidString).json")
        try JSONEncoder().encode(plan).write(to: request, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:request.path)
        defer { try? FileManager.default.removeItem(at: request) }
        let command = try AppStoreUpdatePlan.authorizationCommand(helper: helper, bridge: bridge, plan: request, hostTeam: team)
        let log = directory.appending(path: plan.id.uuidString + "-authorization.log")
        let data: Data
        do { data = try await authorize.run(command, log) }
        catch is CancellationError { throw CancellationError() }
        catch {
            let detail = (try? String(contentsOf: log, encoding: .utf8)).map(StoreInstallationFailure.sanitized)
            throw StoreInstallationError(.init(stage: "authorization", error: error, detail: detail))
        }
        let receipt = try JSONDecoder().decode(AppStoreUpdateReceipt.self, from: data)
        guard receipt.plan.id == plan.id else { throw PeerError.invalid("Unexpected Store transaction identity") }
        if let failure = receipt.failure { throw StoreInstallationError(failure) }
        guard receipt.plan.id == plan.id, ["installed","current"].contains(receipt.state), let updated = receipt.installedApplication else {
            throw PeerError.invalid(String(localized: "商店更新结果尚未确认，请重新检测；不要立即重复发起更新。"))
        }
        try plan.verifyInstalled(updated)
        try JSONEncoder().encode(receipt).write(to: directory.appending(path: plan.id.uuidString+".json"), options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:directory.appending(path:plan.id.uuidString+".json").path)
        await AppStoreCatalog.shared.invalidate()
        if receipt.state == "current" { throw AppStoreAlreadyCurrent() }
    }
}
