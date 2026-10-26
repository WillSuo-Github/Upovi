import Foundation
import UpoviCore

extension AppStore {
    /// A relaunched or failed task never reuses historical URLs, proofs, or installation consent.
    func retryDownload(_ record: DownloadRecord) {
        guard !installationBusy, !refreshing, !checking, !scanning else { return }
        refreshAll()
        let refresh = checkTask
        retryTask = Task {
            await refresh?.value
            guard !Task.isCancelled, refresh?.isCancelled != true, networkAvailable, !installationBusy, !refreshing, !checking, !scanning else { return }
            guard let app = apps.first(where: { $0.id == record.applicationID && $0.bundleID == record.bundleID && $0.teamID == record.teamID && !$0.isAppStore }), !ignored.contains(app.bundleID) else {
                errorMessage = "原应用已移动或开发者身份变化，请从最新应用清单重新选择。"; return
            }
            let candidates = assessment(for: app).sourceUpdates.filter { !$0.isCommunity && $0.download?.hasIntegrityProof == true }
                .sorted {
                    let order = VersionOrder.compare($0.version, $1.version)
                    return order == .orderedSame ? VersionOrder.compare($0.build, $1.build) == .orderedDescending : order == .orderedDescending
                }
            guard let candidate = candidates.first else { errorMessage = "重新检测后没有可验证的更新，请查看来源状态或使用官方更新。"; return }
            selection = app.id
            prepareInstallation(candidate, app: app)
        }
    }
}
