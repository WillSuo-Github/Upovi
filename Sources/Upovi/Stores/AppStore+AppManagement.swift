import Foundation
import UpoviCore

extension AppStore {
    static let appManagementBlockedKey = "appManagementBlockedApplicationsV1"
    static let appManagementEvidenceKey = "appManagementAccessEvidenceV1"

    func dismissAppManagementGuide() {
        let context = appManagementGuide
        appManagementGuide = nil
        UpoviLog.authorization.info("event=appManagement.guideDismissed context=\(context?.rawValue ?? "none")")
    }

    /// Access help is always opened by the user. Neither missing probe history nor
    /// a past write failure establishes the current system permission setting.
    func presentAppManagementHelp() {
        guard !installationBusy, !bulkUpdatePresented, diagnosticsPresentation == nil else { return }
        appManagementGuide = appManagementRetryRecord == nil ? .settings : .accessDenied
        UpoviLog.authorization.info("event=appManagement.guidePresented context=\(appManagementGuide?.rawValue ?? "none") blocked=\(appManagementBlockedIDs.count) trigger=user")
    }

    func recordAppManagementBlock(appID: String?, error: any Error) {
        guard let appID, let storeError = error as? StoreInstallationError, storeError.failure.requiresAppManagement else { return }
        appManagementAccessChecks = []; appManagementAccessCheckedAt = nil
        persistAppManagementEvidence()
        appManagementBlockedIDs.insert(appID)
        preferences.set(appManagementBlockedIDs.sorted(), forKey: Self.appManagementBlockedKey)
        UpoviLog.authorization.warning("event=appManagement.blocked app=\(UpoviDiagnosticContext.applicationID(appID)) code=\(storeError.failure.code)")
    }

    func resolveAppManagementBlock(_ appID: String) {
        guard appManagementBlockedIDs.remove(appID) != nil else { return }
        preferences.set(appManagementBlockedIDs.sorted(), forKey: Self.appManagementBlockedKey)
        UpoviLog.authorization.info("event=appManagement.resolved app=\(UpoviDiagnosticContext.applicationID(appID))")
    }

    func recordSuccessfulAppManagementAccess(_ app: InstalledApp) {
        guard app.isAppStore else { return }
        appManagementAccessChecks.removeAll { $0.id == app.id }
        appManagementAccessChecks.append(.init(id: app.id, name: app.name, verified: true, failure: nil))
        appManagementAccessChecks = Array(appManagementAccessChecks.suffix(20))
        appManagementAccessCheckedAt = Date()
        persistAppManagementEvidence()
        UpoviLog.authorization.info("event=appManagement.installAccessRecorded app=\(UpoviDiagnosticContext.applicationID(app.id))")
    }

    private func persistAppManagementEvidence() {
        let evidence = AppManagementAccessEvidence(checks: appManagementAccessChecks, checkedAt: appManagementAccessCheckedAt ?? Date())
        if let data = try? JSONEncoder().encode(evidence) { preferences.set(data, forKey: Self.appManagementEvidenceKey) }
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
