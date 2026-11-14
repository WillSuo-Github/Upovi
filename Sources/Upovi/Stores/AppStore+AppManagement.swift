import Foundation
import UpoviCore

extension AppStore {
    static let appManagementGuideSeenKey = "appManagementGuideSeenV1"
    static let appManagementBlockedKey = "appManagementBlockedApplicationsV1"

    func offerAppManagementIntroduction() {
        guard !appManagementIntroductionOffered, !preferences.bool(forKey: Self.appManagementGuideSeenKey),
              !installationBusy, !bulkUpdatePresented, diagnosticsPresentation == nil, errorMessage == nil else { return }
        appManagementIntroductionOffered = true
        appManagementGuide = appManagementBlockedIDs.isEmpty ? .firstLaunch : .permissionRequired
        UpoviLog.authorization.info("event=appManagement.guidePresented context=firstLaunch blocked=\(appManagementBlockedIDs.count)")
    }

    func dismissAppManagementGuide() {
        let context = appManagementGuide
        appManagementGuide = nil
        if context == .firstLaunch || context == .permissionRequired {
            preferences.set(true, forKey: Self.appManagementGuideSeenKey)
        }
        UpoviLog.authorization.info("event=appManagement.guideDismissed context=\(context?.rawValue ?? "none")")
    }

    func presentAppManagementHelp() {
        guard !installationBusy, !bulkUpdatePresented, diagnosticsPresentation == nil else { return }
        appManagementGuide = appManagementBlockedIDs.isEmpty ? .settings : .permissionRequired
        UpoviLog.authorization.info("event=appManagement.guidePresented context=\(appManagementGuide?.rawValue ?? "none") blocked=\(appManagementBlockedIDs.count)")
    }

    func presentAppManagementHelpAfterBatch() {
        guard appManagementDeniedDuringBatch else { return }
        appManagementDeniedDuringBatch = false
        guard !appManagementBlockedIDs.isEmpty, appManagementGuide == nil else { return }
        presentAppManagementHelp()
    }

    func recordAppManagementBlock(appID: String?, error: any Error) {
        guard let appID, let storeError = error as? StoreInstallationError, storeError.failure.requiresAppManagement else { return }
        appManagementAccessChecks = []; appManagementAccessCheckedAt = nil
        appManagementBlockedIDs.insert(appID)
        if bulkUpdating { appManagementDeniedDuringBatch = true }
        preferences.set(appManagementBlockedIDs.sorted(), forKey: Self.appManagementBlockedKey)
        UpoviLog.authorization.warning("event=appManagement.blocked app=\(UpoviDiagnosticContext.applicationID(appID)) code=\(storeError.failure.code)")
    }

    func resolveAppManagementBlock(_ appID: String) {
        guard appManagementBlockedIDs.remove(appID) != nil else { return }
        preferences.set(appManagementBlockedIDs.sorted(), forKey: Self.appManagementBlockedKey)
        UpoviLog.authorization.info("event=appManagement.resolved app=\(UpoviDiagnosticContext.applicationID(appID))")
    }

    /// Keep the latest recorded outcome for each blocked app. Permission retries never include
    /// unrelated failures, completed applications or tools, and still go through refresh + review.
    var appManagementRetryRecord: BulkUpdateRecord? {
        var seen = Set<String>(), entries: [BulkUpdateRecord.Entry] = []
        for record in batchHistory {
            for entry in record.entries where appManagementBlockedIDs.contains(entry.item.id) {
                guard seen.insert(entry.item.id).inserted else { continue }
                if entry.phase == .failed, entry.item.application.isAppStore { entries.append(entry) }
            }
        }
        guard !entries.isEmpty else { return nil }
        var record = BulkUpdateRecord(items: entries.map(\.item))
        record.entries = entries
        return record
    }

    func reviewAppManagementBlockedUpdates() {
        guard !operationBusy, let record = appManagementRetryRecord else { return }
        UpoviLog.authorization.info("event=appManagement.retryReviewRequested applications=\(record.entries.count)")
        dismissAppManagementGuide()
        retryBatch(record)
    }

    var appManagementBlockedAccessVerified: Bool {
        !appManagementBlockedIDs.isEmpty && Set(appManagementAccessChecks.filter(\.verified).map(\.id)).isSuperset(of: appManagementBlockedIDs)
    }

    func verifyAppManagementAccess() {
        guard !operationBusy, !appManagementAccessChecking else { return }
        appManagementAccessChecking = true; appManagementAccessError = nil
        appManagementAccessChecks = []; appManagementAccessCheckedAt = nil
        Task {
            defer { appManagementAccessChecking = false }
            do {
                let inventory = await appManagementAccessInventory()
                let storeApps = inventory.filter { $0.isAppStore && URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == "/Applications" }
                let blocked = storeApps.filter { appManagementBlockedIDs.contains($0.id) }
                let targets = Array((blocked.isEmpty ? storeApps.prefix(1).map { $0 } : blocked).prefix(20))
                guard !targets.isEmpty else { throw PeerError.unavailable(String(localized: "尚无可验证的商店应用。权限状态未确认；可先打开系统设置。")) }
                let results = try await appManagementAccessVerifier(targets)
                appManagementAccessChecks = results.map { receipt in
                    .init(id: receipt.plan.application.id, name: receipt.plan.application.name,
                          verified: receipt.failure == nil && receipt.state == "accessVerified",
                          failure: receipt.failure.map { _ in String(localized: "写入访问仍受阻。若系统开关已开启，请保留诊断信息，勿反复切换权限。") })
                }
                for receipt in results {
                    if let failure = receipt.failure { recordDiagnostic(.installation, appID: receipt.plan.application.id, error: StoreInstallationError(failure)) }
                }
                appManagementAccessCheckedAt = Date()
                // Probe success is evidence for this target at this time, not an installation outcome.
                // Keep pending update tasks and confirmation requirements intact.
            } catch is CancellationError { appManagementAccessError = String(localized: "验证已取消，权限状态未确认。") }
            catch {
                recordDiagnostic(.installation, error: error)
                appManagementAccessError = String(localized: "访问验证未完成。请重试；仍失败时请从设置导出诊断信息。")
            }
        }
    }

    @discardableResult func openAppManagementSettings() -> Bool {
        let operation = UpoviLogOperation("appManagement.openSettings", category: .authorization)
        appManagementAccessChecks = []; appManagementAccessCheckedAt = nil
        let opened = appManagementSettingsOpener()
        operation.finish(opened ? "opened" : "failed", level: opened ? .info : .warning)
        // Visiting Settings is not evidence that consent was granted. No retry runs here.
        return opened
    }

    @discardableResult func revealAppManagementInstaller() -> Bool {
        let operation = UpoviLogOperation("appManagement.revealInstaller", category: .authorization)
        let revealed = appManagementInstallerRevealer()
        operation.finish(revealed ? "revealed" : "unavailable", level: revealed ? .info : .warning)
        return revealed
    }
}
