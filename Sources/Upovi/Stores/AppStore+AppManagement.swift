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

    @discardableResult func openAppManagementSettings() -> Bool {
        let operation = UpoviLogOperation("appManagement.openSettings", category: .authorization)
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
