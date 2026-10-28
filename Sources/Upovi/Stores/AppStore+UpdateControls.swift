import AppKit
import Foundation
import UpoviCore

extension AppStore {
    func fullAssessment(for app: InstalledApp) -> UpdateAssessment {
        UpdateAssessment(app: app, sourceResult: sourceResults[app.id], reports: networkEnabled ? communityResults[app.id] ?? [] : [])
    }
    var actionableSourceResults: [String: SourceResult] {
        Dictionary(uniqueKeysWithValues: apps.compactMap { app in
            sourceResults[app.id].map { (app.id, updatePolicy.filtering($0, app: app, now: policyClock)) }
        })
    }
    func setSkipped(_ candidate: UpdateCandidate, app: InstalledApp, skipped: Bool) {
        var next = updatePolicy
        let key = UpdatePolicy.key(candidate, app: app)
        if skipped { next.skipped.insert(key) } else { next.skipped.remove(key) }
        saveUpdatePolicy(next)
    }
    func deferUpdates(for app: InstalledApp, until date: Date?) {
        var next = updatePolicy; next.deferredUntil[UpdatePolicy.scope(app)] = date
        guard saveUpdatePolicy(next) else { return }
        if date != nil && notificationsEnabled { notifications.allowReminder(for: app) }
    }
    func clearUpdatePolicy() { saveUpdatePolicy(UpdatePolicy()) }
    @discardableResult
    private func saveUpdatePolicy(_ value: UpdatePolicy) -> Bool {
        guard let data = try? JSONEncoder().encode(value), preferences.set(data, forKey: "updatePolicyV1") else { return false }
        updatePolicy = value; policyClock = Date()
        return true
    }
    func scanInventory() async -> [InstalledApp] {
        let roots = ScanLocations.defaults + additionalScanDirectories.map { URL(fileURLWithPath: $0) }
        return await scanApplications(roots)
    }
    func chooseScanDirectory() {
        guard !refreshing, !scanning, !checking, !installationBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.message = String(localized: "选择额外扫描的应用目录；全局 P2P 开启时，扫描到的应用也会参与版本共享。")
        guard panel.runModal() == .OK else { return }
        setScanDirectories(additionalScanDirectories + panel.urls.map(\.path))
    }
    func setScanDirectories(_ paths: [String]) {
        guard !refreshing, !scanning, !checking, !installationBusy else { return }
        let normalized = ScanLocations.normalized(paths)
        guard preferences.set(normalized, forKey: "scanDirectoriesV1") else { return }
        additionalScanDirectories = normalized
        refreshAll()
    }
}
