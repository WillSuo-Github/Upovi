import Foundation
import UpoviCore

extension AppStore {
    @discardableResult
    func saveBatchHistory() -> Bool {
        guard let data = try? JSONEncoder().encode(batchHistory) else { return false }
        return preferences.set(data, forKey: "bulkHistoryV1")
    }
    @discardableResult
    func saveBulkPhase(_ id: String, phase: BulkUpdateRecord.Phase, detail: String) -> Bool {
        guard let index = batchHistory.firstIndex(where: { $0.id == bulkRecordID }) else { return false }
        batchHistory[index].update(id, phase: phase, detail: detail)
        let saved = saveBatchHistory()
        if !saved { bulkPersistenceFailed = true; bulkStopRequested = true }
        return saved
    }
    func retryBatch(_ record: BulkUpdateRecord) {
        guard !installationBusy, !refreshing, !checking, !scanning else { return }
        let ids = record.retryIDs
        guard !ids.isEmpty else { return }
        bulkUpdatePresented = false
        refreshAll()
        let refresh = checkTask
        retryTask = Task {
            await refresh?.value
            guard !Task.isCancelled, refresh?.isCancelled != true, networkAvailable, !installationBusy, !refreshing, !checking, !scanning else { return }
            let original = Dictionary(record.entries.map { ($0.item.id, $0.item) }, uniquingKeysWith: { first, _ in first })
            let targets = apps.filter { app in
                guard ids.contains(app.id), let old = original[app.id],
                      old.application.bundleID == app.bundleID, old.application.teamID == app.teamID,
                      old.application.channel == app.channel else { return false }
                // Another updater or later batch may already have completed the recorded target.
                return old.candidate.usesBuildVersion
                    ? VersionOrder.compare(old.candidate.build, app.build) == .orderedDescending
                    : VersionOrder.isNewer(version: old.candidate.version, build: old.candidate.build, than: app)
            }
            let plan = BulkUpdatePlan.make(apps: targets, results: actionableSourceResults, ignored: ignored)
            guard !plan.isEmpty else { errorMessage = String(localized: "原清单中未完成的应用已无可处理的更新，或来源尚未确认；请查看最新检测结果。"); return }
            bulkItems = plan; bulkOutcomes = [:]; bulkActiveIDs = []; clearBulkTransfers()
            bulkHasRun = false; bulkStopRequested = false
            bulkUpdatePresented = true
        }
    }
}
