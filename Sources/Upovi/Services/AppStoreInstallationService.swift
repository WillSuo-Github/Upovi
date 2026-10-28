import Darwin
import Foundation
import UpoviCore

@MainActor final class AppStoreInstallationService {
    private let directory: URL
    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Upovi/StoreAttempts")) { self.directory = directory }
    func perform(_ candidate: UpdateCandidate, app: InstalledApp) async throws {
        guard !candidate.isCommunity, let id = candidate.appStoreID,
              let helper = Bundle.main.url(forAuxiliaryExecutable: "UpoviStoreInstaller"),
              let bridge = Bundle.main.url(forAuxiliaryExecutable: "UpoviStoreBridge"),
              let team = AdministratorAuthorization.teamID(at: Bundle.main.bundleURL) else {
            throw PeerError.unavailable(String(localized: "请使用包含商店更新组件的 Developer ID 签名 Upovi 应用包。"))
        }
        let plan = AppStoreUpdatePlan(application: app, storeID: id, version: candidate.version, userID: getuid())
        try plan.validate()
        try await UpdateInstaller.requestApplicationQuit(app)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let request = directory.appending(path: "Request-\(plan.id.uuidString).json")
        try JSONEncoder().encode(plan).write(to: request, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:request.path)
        defer { try? FileManager.default.removeItem(at: request) }
        let script = try AppStoreUpdatePlan.authorizationScript(helper: helper, bridge: bridge, plan: request, hostTeam: team)
        let data: Data
        do { data = try await ProcessCommand().run("/usr/bin/osascript", ["-e",script], timeoutSeconds:2100, maximumOutputBytes:65536) }
        catch { throw PeerError.unavailable(String(localized: "商店更新尚未确认完成。请检查账户和管理员认证，重新检测后再操作；已交给 Apple 的后台任务可能仍在继续。")) }
        let receipt = try JSONDecoder().decode(AppStoreUpdateReceipt.self, from: data)
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
