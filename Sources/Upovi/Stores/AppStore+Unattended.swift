import AppKit
import Foundation
import UpoviCore

private struct UnattendedDeferred: Error { let reason: UnattendedUpdatePolicy.Deferral }

extension AppStore {
    func releaseChannel(for app: InstalledApp) -> ReleaseChannel { sourceOverrides[app.bundleID]?.releaseChannel ?? .stable }

    func revokeAutomaticUpdatesBeforeRestore(_ app: InstalledApp) -> Bool {
        guard unattendedState.grants.contains(where: { $0.id == app.id }) else { return true }
        var next = unattendedState
        next.grants.removeAll { $0.id == app.id }; next.attempts[app.id] = nil
        return saveUnattendedState(next)
    }

    func setReleaseChannel(_ channel: ReleaseChannel, for app: InstalledApp) {
        guard !app.isAppStore, channel != releaseChannel(for: app) else { return }
        // Revoke automatic consent first: a channel change never silently opts an app into Beta installs.
        var automatic = unattendedState
        automatic.grants.removeAll { $0.application.bundleID == app.bundleID }
        automatic.attempts = automatic.attempts.filter { key, _ in automatic.grants.contains { $0.id == key } }
        guard saveUnattendedState(automatic) else { return }
        var next = sourceOverrides
        var source = next[app.bundleID] ?? .init()
        source.releaseChannel = channel; next[app.bundleID] = source
        guard let data = try? JSONEncoder().encode(next), preferences.set(data, forKey: "sourceOverridesV1") else { return }
        sourceOverrides = next; sourceResults = [:]; unattendedTask?.cancel(); cancelChecking()
    }

    @discardableResult func setUnattendedEnabled(_ enabled: Bool) -> Bool {
        var next = unattendedState; next.enabled = enabled
        guard saveUnattendedState(next) else { return false }
        if !enabled { unattendedTask?.cancel() }
        return true
    }

    func setUnattendedAllowed(_ allowed: Bool, for app: InstalledApp) {
        var next = unattendedState
        next.grants.removeAll { $0.id == app.id }
        if allowed {
            do {
                guard next.grants.count < 500 else { throw PeerError.invalid("Too many unattended update permissions") }
                next.grants.append(try .init(application: app, channel: releaseChannel(for: app)))
            } catch { errorMessage = String(localized: "此应用的身份不支持无人值守更新。"); return }
        }
        next.attempts = next.attempts.filter { key, _ in next.grants.contains { $0.id == key } }
        if saveUnattendedState(next), !allowed { unattendedTask?.cancel() }
    }

    @discardableResult func saveUnattendedState(_ next: UnattendedUpdateState) -> Bool {
        guard let data = try? JSONEncoder().encode(next), preferences.set(data, forKey: "unattendedUpdatesV1") else { return false }
        unattendedState = next; return true
    }

    func beginUnattendedUpdates() {
        guard unattendedState.enabled, !operationBusy, !bulkUpdatePresented,
              !SelfUpdateService.shared.sessionInProgress, networkAvailable,
              let lastChecked, Date().timeIntervalSince(lastChecked) >= 0,
              Date().timeIntervalSince(lastChecked) <= 300 else { return }
        let targets = apps.filter { unattendedState.grant(for: $0, channel: releaseChannel(for: $0)) != nil }
        guard !targets.isEmpty else { return }
        unattendedUpdating = true
        unattendedTask = Task { [self] in
            defer { unattendedUpdating = false }
            var revalidatedAt = Date.distantPast
            for app in targets {
                if Task.isCancelled || !unattendedState.enabled || !networkAvailable { break }
                if Date().timeIntervalSince(revalidatedAt) >= 300 {
                    await revalidateSources(); revalidatedAt = Date()
                    if Task.isCancelled { break }
                }
                let channel = releaseChannel(for: app)
                let fresh = await checkApplication(app, sourceOverrides[app.bundleID])
                guard !Task.isCancelled, channel == releaseChannel(for: app) else { break }
                sourceResults[app.id] = fresh
                guard let item = BulkUpdatePlan.make(apps: [app], results: [app.id: fresh], ignored: ignored).first,
                      item.canInstall, unattendedDeferral(item) == nil else { continue }
                var record = UnattendedUpdateRecord(app: app, candidate: item.candidate, channel: channel)
                var state = unattendedState; state.record(record)
                guard saveUnattendedState(state) else { break }
                beginTransfer(app.id)
                do {
                    let checkpoint: @MainActor () throws -> Void = { [self, record] in
                        try Task.checkCancellation()
                        guard networkAvailable, !SelfUpdateService.shared.sessionInProgress else { throw CancellationError() }
                        if let reason = unattendedDeferral(item, currentAttempt: record.id) { throw UnattendedDeferred(reason: reason) }
                        var installing = record; installing.phase = .installing
                        var next = unattendedState; next.record(installing)
                        guard saveUnattendedState(next) else { throw PeerError.unavailable("Unattended history could not be saved") }
                        setTransferPhase(app.id, .installing)
                    }
                    if let unattendedOperation { try await unattendedOperation(item, checkpoint) }
                    else { try await applyUnattended(item, checkpoint: checkpoint) }
                    record.phase = .installed; record.detail = String(localized: "自动更新完成，主应用备份已保留。")
                    sourceResults[app.id] = nil
                } catch is ApplicationAlreadyCurrent {
                    record.phase = .current; record.detail = String(localized: "已安装选定版本或更高版本，未重复安装")
                    sourceResults[app.id] = .init(appID: app.id, candidates: [], note: record.detail, status: .current)
                } catch is UnattendedDeferred {
                    record.phase = .deferred; record.detail = String(localized: "应用状态或自动更新权限已变化，安装已推迟。")
                } catch {
                    record.phase = error is CancellationError ? .cancelled : .failed
                    record.detail = error is CancellationError ? String(localized: "已取消，未完成安装") : error.localizedDescription
                    recordDiagnostic(.installation, appID: app.id, error: error)
                }
                record.finishedAt = Date(); transfers[app.id] = nil
                var completed = unattendedState; completed.record(record)
                guard saveUnattendedState(completed) else { break }
            }
            apps = await scanInventory()
            await refreshInstallations()
        }
    }

    func unattendedDeferral(_ item: BulkUpdateItem, currentAttempt: UUID? = nil) -> UnattendedUpdatePolicy.Deferral? {
        let app = item.application
        return UnattendedUpdatePolicy.deferral(app: app, candidate: item.candidate, result: sourceResults[app.id],
            state: unattendedState, channel: releaseChannel(for: app), ignored: ignored, updatePolicy: updatePolicy,
            running: !runningUpdateApplications([app]).isEmpty, writable: unattendedWritable(app), currentAttempt: currentAttempt)
    }

    private func applyUnattended(_ item: BulkUpdateItem, checkpoint: @escaping @MainActor () throws -> Void) async throws {
        let app = item.application
        let prepared = try await installer.prepare(app: app, candidate: item.candidate, progress: { [weak self] received, expected in
            Task { @MainActor in self?.reportDownload(app.id, received: received, expected: expected) }
        })
        do {
            try checkpoint()
            _ = try await installer.install(prepared.id, requireNotRunning: true)
            await installer.discard(prepared.id)
        } catch { await installer.discard(prepared.id); throw error }
    }
}
