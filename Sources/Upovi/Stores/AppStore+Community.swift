import Foundation
import UpoviCore

extension AppStore {
    var p2pScope: [InstalledApp] { GlobalP2PScope.applications(apps) }

    /// Serialize stop/start transitions so a late stop cannot shut down a newer session.
    func restartP2P() {
        p2pGeneration &+= 1
        let generation = p2pGeneration
        let previous = p2pControlTask, synchronization = syncTask
        previous?.cancel(); synchronization?.cancel()
        p2pTransitioning = true
        p2pControlTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await community.stop()
            await synchronization?.value
            guard !Task.isCancelled, generation == p2pGeneration else { return }
            if networkEnabled { await community.resume() }
            guard !Task.isCancelled, generation == p2pGeneration else { return }
            p2pTransitioning = false
            if networkEnabled { beginSync() }
        }
    }

    func beginSync() {
        guard networkEnabled, networkAvailable, !p2pTransitioning, !syncing, !scanning, !installing else { return }
        syncing = true; lastSyncAttempt = Date()
        let generation = p2pGeneration
        logger.info("community sync started")
        syncTask = Task { await syncCommunity(generation: generation) }
    }

    private func loadIdentity() async throws -> PeerIdentity {
        if let identity { return identity }
        let loading = Task.detached {
            try Task.checkCancellation()
            return try PeerIdentity.loadOrCreate(account: "public-dht-v2")
        }
        let loaded = try await withTaskCancellationHandler { try await loading.value } onCancel: { loading.cancel() }
        try Task.checkCancellation()
        identity = loaded; identityID = loaded.invitation.shortID
        return loaded
    }

    private func syncCommunity(generation: UInt64) async {
        defer { syncing = false; p2pProgress = "" }
        let localCopies = Dictionary(grouping: apps, by: { CommunityTopic.hash($0) })
        let scope = p2pScope
        let batch = GlobalP2PScope.batch(scope, offset: p2pBatchOffset)
        guard !batch.apps.isEmpty else { networkStatus = "P2P 已开启，扫描到应用后会自动参与"; return }
        let activeIDs = Set(apps.map(\.id))
        communityResults = communityResults.filter { activeIDs.contains($0.key) }
        discoveredPublishers = discoveredPublishers.filter { Date().timeIntervalSince($0.value.lastSeen) < 86400 }
        let activeTopics = Set(scope.map { CommunityTopic.hash($0).base64EncodedString() })
        publisherCache = publisherCache.filter { activeTopics.contains($0.key) }
        var announcements = 0, storage = 0, directoryAcks = 0, directoryCandidates = 0
        var failedRecords = 0, rejectedReports = 0, found = 0, responders = 0, endpoints = 0, unreachable = 0, failures = 0
        var lastFailure = ""
        networkStatus = "正在发现并共享应用版本…"
        do {
            try Task.checkCancellation()
            let identity = try await loadIdentity()
            try Task.checkCancellation()
            try await community.prepare(apps: batch.apps, sharingIdentity: identity)
        } catch { if !Task.isCancelled, generation == p2pGeneration, networkEnabled { networkStatus = error.localizedDescription }; return }
        for (index, app) in batch.apps.enumerated() {
            guard !Task.isCancelled, networkEnabled, generation == p2pGeneration else { return }
            p2pProgress = "\(batch.start + index + 1)/\(batch.total) · \(app.name)"
            let topicHash = CommunityTopic.hash(app)
            let copies = localCopies[topicHash] ?? [app]
            for copy in copies { communityResults[copy.id] = nil }
            do {
                let result = try await community.publish(app)
                announcements += result.announcements; storage += result.storage; directoryAcks += result.directory
            } catch { if Task.isCancelled { return }; failures += 1; lastFailure = error.localizedDescription }
            guard !Task.isCancelled, networkEnabled, generation == p2pGeneration else { return }
            do {
                let topic = topicHash.base64EncodedString()
                let keys = (publisherCache[topic] ?? []).compactMap { Data(base64Encoded: $0) }
                let result = try await community.discover(app, cachedKeys: keys)
                guard !Task.isCancelled, networkEnabled, generation == p2pGeneration else { return }
                responders += result.responders; endpoints += result.endpoints; unreachable += result.unreachable
                directoryCandidates += result.directoryCandidates; failedRecords += result.failedRecords; rejectedReports += result.rejectedReports
                var discoveredKeys = publisherCache[topic] ?? []
                for observation in result.observations {
                    if !discoveredKeys.contains(observation.id) { discoveredKeys.append(observation.id) }
                    var publisher = discoveredPublishers[observation.id] ?? DiscoveredPublisher(id: observation.id,
                        shortID: observation.shortID, applications: [], lastSeen: observation.report.observedAt)
                    publisher.applications.insert(app.name)
                    publisher.lastSeen = max(publisher.lastSeen, observation.report.observedAt)
                    discoveredPublishers[observation.id] = publisher
                    let report = observation.report
                    var hasLead = false
                    for copy in copies where VersionOrder.isNewer(version: report.version, build: report.build, than: copy) {
                        communityResults[copy.id, default: []].append(.init(version: report.version, build: report.build,
                            source: "公开节点 \(observation.shortID)", isCommunity: true, url: nil,
                            observedAt: report.observedAt, peerID: observation.id, expiresAt: report.expiresAt))
                        hasLead = true
                    }
                    if hasLead { found += 1 }
                }
                publisherCache[topic] = Array(discoveredKeys.prefix(16))
                // Preserve other batches' verified keys, with a bounded total cache.
                if publisherCache.count > 2048 {
                    publisherCache = Dictionary(uniqueKeysWithValues: publisherCache.sorted { $0.key < $1.key }.prefix(2048).map { ($0.key, $0.value) })
                }
            } catch { if Task.isCancelled { return }; failures += 1; lastFailure = error.localizedDescription }
            guard !Task.isCancelled, networkEnabled, generation == p2pGeneration else { return }
            p2pBatchOffset = (batch.start + index + 1) % batch.total
            try? await Task.sleep(for: .milliseconds(400))
        }
        guard !Task.isCancelled, networkEnabled, generation == p2pGeneration else { return }
        p2pBatchOffset = batch.nextOffset
        AppPreferences.shared.set(publisherCache, forKey: "publicPublisherCacheV2")
        lastSynced = Date()
        logger.info("community sync completed apps=\(batch.apps.count) publishers=\(self.discoveredPublishers.count) leads=\(found) failures=\(failures)")
        networkStatus = "已同步 \(batch.start + 1)–\(batch.start + batch.apps.count)/\(batch.total) 个应用 · 验签节点 \(discoveredPublishers.count) 个 · 更高版本线索 \(found) 条"
        networkStatus += "\nDHT 响应 \(responders) 次 · 端点 \(endpoints) 个 · 索引候选 \(directoryCandidates) 个"
        networkStatus += "\n主题登记确认 \(announcements) 次 · 索引登记确认 \(directoryAcks) 次 · 记录存储确认 \(storage) 次"
        if unreachable > 0 { networkStatus += "\n\(unreachable) 个采样端点未返回有效记录" }
        if failedRecords > 0 { networkStatus += "\n\(failedRecords) 个索引候选未返回有效签名记录" }
        if rejectedReports > 0 { networkStatus += "\n已拒绝 \(rejectedReports) 条回放、冲突或无效报告" }
        if failures > 0 { networkStatus += "\n\(failures) 项失败：\(lastFailure)" }
    }
}
