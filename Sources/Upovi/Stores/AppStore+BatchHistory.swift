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
    func retryBatch(_ record: BulkUpdateRecord, toolSources: [ToolSource] = []) {
        guard !installationBusy, !refreshing, !checking, !scanning else { return }
        let ids = record.retryIDs
        guard !ids.isEmpty else { return }
        bulkUpdatePresented = false
        // Leave the finished summary so the header shows the recheck progress and its Cancel button.
        dismissBulkSummary()
        refreshAll()
        let refresh = checkTask
        retryTask = Task {
            await refresh?.value
            guard !Task.isCancelled, refresh?.isCancelled != true, networkAvailable, !installationBusy, !refreshing, !checking, !scanning else { return }
            let original = Dictionary(record.entries.map { ($0.item.id, $0.item) }, uniquingKeysWith: { first, _ in first })
            let repairs = apps.filter { ids.contains($0.id) }.compactMap { storeReceiptRecoveryItem($0) }
            logger.info("Batch retry matched \(self.apps.filter { ids.contains($0.id) }.count) installed apps and \(repairs.count) Store receipt repairs")
            let targets = apps.filter { app in
                guard ids.contains(app.id), let old = original[app.id],
                      old.application.bundleID == app.bundleID, old.application.teamID == app.teamID,
                      old.application.channel == app.channel else { return false }
                // Another updater or later batch may already have completed the recorded target.
                return old.candidate.isNewer(than: app)
            }
            let plan = repairs + BulkUpdatePlan.make(apps: targets, results: actionableSourceResults, ignored: ignored)
            toolBatchSources = toolSources.filter { enabledToolSources.contains($0) && toolLocations[$0] != nil }
            guard !plan.isEmpty || !toolBatchSources.isEmpty else { errorMessage = String(localized: "原清单中未完成的应用已无可处理的更新，或来源尚未确认；请查看最新检测结果。"); return }
            bulkItems = plan; bulkOutcomes = [:]; bulkActiveIDs = []; clearBulkTransfers()
            toolOutcomes = [:]
            bulkHasRun = false; bulkStopRequested = false
            bulkUpdatePresented = true
        }
    }
}
