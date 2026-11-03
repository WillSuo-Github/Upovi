import XCTest
@testable import UpoviCore
@testable import Upovi

@MainActor final class ToolSourceWorkflowTests: XCTestCase {
    private func store(downloads: DownloadCoordinator? = nil) throws -> (AppStore, AppPreferences) {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-tool-workflow-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let preferences = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        preferences.set(false, forKey: GlobalP2PSettings.key)
        let installer = UpdateInstaller(journalDirectory: root.appending(path: "Journal"),
            downloadCache: ArtifactDownloadCache(directory: root.appending(path: "Cache")), downloads: downloads)
        let value = AppStore(preferences: preferences, installer: installer, scanApplications: { _ in [] }, revalidateSources: { })
        value.administrator = AdministratorInstallationService(directory: root.appending(path: "Attempts"), downloads: installer.downloads)
        value.toolLocations = [.npm: URL(fileURLWithPath: "/fixture/npm"), .uv: URL(fileURLWithPath: "/fixture/uv")]
        value.checkToolSource = { source, _ in .init(source: source, context: "/fixture/global", installed: ["tool":"1.0"], updates: [.init(name: "tool", installed: "1.0", available: "2.0")]) }
        return (value, preferences)
    }
    func testSourcesDefaultOffAndEnablingOnlyChecksAndPersists() async throws {
        let (value, preferences) = try store()
        XCTAssertTrue(value.enabledToolSources.isEmpty)
        value.updateToolPackage = { _, _ in XCTFail("A toggle must not update packages"); throw PeerError.invalid("Unexpected write") }
        value.setToolSource(.npm, enabled: true)
        await value.toolCheckTask?.value
        XCTAssertEqual(value.toolSnapshots[.npm]?.updates.count, 1)
        XCTAssertEqual(AppStore(preferences: preferences).enabledToolSources, [.npm])
        value.setToolSource(.npm, enabled: false)
        await value.toolCheckTask?.value
        XCTAssertTrue(value.availableToolSources.isEmpty)
    }
    func testToolsOnlyParticipateInUpdateAllAndPersistVerifiedHistory() async throws {
        let (value, preferences) = try store()
        value.updateToolPackage = { item, _ in .init(source: item.source, context: "/fixture/global", installed: ["tool":"2.0"], updates: []) }
        value.setToolSource(.npm, enabled: true); await value.toolCheckTask?.value
        value.reviewAllUpdates()
        XCTAssertTrue(value.bulkUpdatePresented); XCTAssertEqual(value.bulkInstallableCount, 1)
        value.startAllUpdates(); await value.bulkTask?.value
        XCTAssertEqual(value.bulkCompletedCount, 1); XCTAssertEqual(value.bulkFailedCount, 0)
        XCTAssertTrue(value.batchHistory.isEmpty)
        XCTAssertEqual(value.toolHistory.first?.state, .succeeded)
        XCTAssertTrue(value.visibleToolUpdates.isEmpty)
        XCTAssertEqual(AppStore(preferences: preferences).toolHistory.first?.state, .succeeded)
        XCTAssertFalse(value.installationBusy)
    }
    func testMixedUpdateAllStartsInDisplayOrderInsteadOfGroupingBySource() async throws {
        let downloads = DownloadCoordinator { _, _, _, _, _, _ in
            throw PeerError.unavailable("Synthetic download failure")
        }
        let (value, _) = try store(downloads: downloads)
        let clash = InstalledApp(name: "Clash Verge", bundleID: "app.synthetic.clash", version: "1",
            path: "/synthetic/Z.app", teamID: "SYNTHETIC")
        let code = InstalledApp(name: "Code", bundleID: "app.synthetic.code", version: "1",
            path: "/synthetic/A.app", teamID: "SYNTHETIC")
        value.apps = [code, clash]
        value.bulkConcurrency = 1
        let candidate = UpdateCandidate(version: "2", source: "Fixture", isCommunity: false, url: nil,
            download: .init(url: URL(string: "https://example.invalid/update.zip")!, sha256: String(repeating: "a", count: 64)))
        for app in value.apps {
            value.sourceResults[app.id] = .init(appID: app.id, candidates: [candidate], note: "", status: .updates)
        }
        let first = ToolPackage(name: "ccusage", installed: "1", available: "2")
        let last = ToolPackage(name: "z-tool", installed: "1", available: "2")
        value.enabledToolSources = [.npm]
        value.toolSnapshots[.npm] = .init(source: .npm, installed: [first.name: "1", last.name: "1"], updates: [last, first])
        value.updateToolPackage = { [weak value] item, _ in
            let started = await downloads.snapshot()
            if item.package.name == first.name {
                XCTAssertTrue(started.isEmpty)
                let phases = await MainActor.run { [value?.transfers[clash.id]?.phase, value?.transfers[code.id]?.phase] }
                XCTAssertEqual(phases, [.queued, .queued])
                return .init(source: .npm, installed: [first.name: "2", last.name: "1"], updates: [last])
            }
            XCTAssertEqual(started.reversed().map(\.applicationID), [clash.id, code.id])
            return .init(source: .npm, installed: [first.name: "2", last.name: "2"], updates: [])
        }
        value.reviewAllUpdates()
        XCTAssertEqual(value.bulkInstallableCount, 4)
        value.startAllUpdates(); await value.bulkTask?.value
        XCTAssertEqual(value.toolHistory.reversed().compactMap { $0.item?.package.name }, [first.name, last.name])
        XCTAssertEqual(value.bulkCompletedCount, 2)
        XCTAssertEqual(value.bulkFailedCount, 2)
    }
    func testStoppingFinishesCurrentSourceAndDoesNotStartTheNext() async throws {
        let (value, _) = try store()
        value.setToolSource(.npm, enabled: true); await value.toolCheckTask?.value
        value.setToolSource(.uv, enabled: true); await value.toolCheckTask?.value
        value.updateToolPackage = { [weak value] item, _ in
            let source = item.source
            XCTAssertEqual(source, .npm)
            await value?.stopAllUpdates()
            return .init(source: source, installed: ["tool":"2.0"], updates: [])
        }
        value.reviewAllUpdates(); value.startAllUpdates(); await value.bulkTask?.value
        XCTAssertEqual(value.bulkCompletedCount, 1)
        XCTAssertEqual(value.toolOutcomes[value.toolBatchItems.first { $0.source == .uv }!.id]?.state, .interrupted)
        XCTAssertEqual(value.toolHistory.count, 1)
    }
    func testInterruptedToolHistoryNeverAutomaticallyResumes() throws {
        let (_, preferences) = try store()
        preferences.set(try JSONEncoder().encode([ToolUpdateRecord(source: .npm)]), forKey: "toolHistoryV1")
        let value = AppStore(preferences: preferences)
        XCTAssertEqual(value.toolHistory.first?.state, .interrupted)
        XCTAssertFalse(value.bulkUpdating); XCTAssertNil(value.bulkTask)
    }
    func testCompletedSourcesLeaveTheListAndRetryTargetsOnlyFailures() async throws {
        let (value, _) = try store()
        value.setToolSource(.npm, enabled: true); await value.toolCheckTask?.value
        value.setToolSource(.uv, enabled: true); await value.toolCheckTask?.value
        value.updateToolPackage = { item, _ in
            let source = item.source
            if source == .npm { throw PeerError.unavailable("Synthetic manager failure") }
            return .init(source: source, installed: ["tool":"2.0"], updates: [])
        }
        value.reviewAllUpdates(); value.startAllUpdates(); await value.bulkTask?.value
        XCTAssertEqual(value.bulkCompletedCount, 1); XCTAssertEqual(value.bulkFailedCount, 1)
        XCTAssertEqual(value.visibleToolUpdates.map(\.source), [.npm]); XCTAssertEqual(value.toolHistory.count, 2)
        value.retryLatestBulkRun()
        XCTAssertEqual(value.toolBatchItems.map(\.source), [.npm])
        value.updateToolPackage = { item, _ in .init(source: item.source, installed: ["tool":"2.0"], updates: []) }
        value.startAllUpdates(); await value.bulkTask?.value
        XCTAssertTrue(value.visibleToolUpdates.isEmpty)
        XCTAssertEqual(value.toolHistory.count, 3)
    }
    func testGlobalRefreshClearsFinishedSummaryAndChecksEnabledTools() async throws {
        let (value, _) = try store()
        value.updateToolPackage = { item, _ in .init(source: item.source, installed: ["tool":"2.0"], updates: []) }
        value.setToolSource(.npm, enabled: true); await value.toolCheckTask?.value
        value.reviewAllUpdates(); value.startAllUpdates(); await value.bulkTask?.value
        XCTAssertTrue(value.bulkSummaryVisible)
        value.refreshAll()
        XCTAssertFalse(value.bulkSummaryVisible)
        await value.checkTask?.value; await value.toolCheckTask?.value
        XCTAssertEqual(value.toolSnapshots[.npm]?.updates.count, 1)
        XCTAssertEqual(value.visibleToolUpdates.map(\.source), [.npm])
    }
    func testOneSourceCreatesIndividualTasksAndRetriesOnlyTheFailedPackage() async throws {
        let (value, preferences) = try store()
        value.enabledToolSources = [.npm]
        value.toolSnapshots[.npm] = .init(source: .npm, context: "/fixture/global", installed: ["alpha":"1", "beta":"1"], updates: [
            .init(name: "alpha", installed: "1", available: "2"), .init(name: "beta", installed: "1", available: "2")])
        value.updateToolPackage = { item, _ in
            if item.package.name == "alpha" { throw PeerError.unavailable("Synthetic alpha failure") }
            return .init(source: .npm, context: item.context, installed: ["alpha":"1", "beta":"2"], updates: [.init(name: "alpha", installed: "1", available: "2")])
        }
        XCTAssertEqual(value.toolUpdateCount, 2)
        XCTAssertTrue(value.matchesSearch(value.pendingToolUpdates[0]))
        value.search = "BETA"; XCTAssertTrue(value.matchesSearch(value.pendingToolUpdates[1])); XCTAssertFalse(value.matchesSearch(value.pendingToolUpdates[0]))
        value.reviewAllUpdates()
        XCTAssertEqual(value.bulkInstallableCount, 2, "Search must not narrow Update All")
        value.startAllUpdates(); await value.bulkTask?.value
        XCTAssertEqual(value.bulkCompletedCount, 1); XCTAssertEqual(value.bulkFailedCount, 1)
        XCTAssertEqual(value.visibleToolUpdates.map { $0.package.name }, ["alpha"])
        XCTAssertNil(value.toolCheckErrors[.npm], "One failed package cannot hide or fail its siblings")
        value.retryLatestBulkRun()
        XCTAssertEqual(value.toolBatchItems.map { $0.package.name }, ["alpha"])
        let saved = AppStore(preferences: preferences).toolHistory
        XCTAssertEqual(Set(saved.compactMap { $0.item?.package.name }), ["alpha", "beta"])
    }
    func testSingleToolUpdateAndEmptySourcesDoNotUpgradeTheWholeSource() async throws {
        let (value, _) = try store()
        value.enabledToolSources = [.npm, .uv]
        value.toolSnapshots[.npm] = .init(source: .npm, installed: ["alpha":"1", "beta":"1"], updates: [
            .init(name: "alpha", installed: "1", available: "2"), .init(name: "beta", installed: "1", available: "2")])
        value.toolSnapshots[.uv] = .init(source: .uv, installed: ["current":"2"], updates: [])
        let selected = value.pendingToolUpdates[0]
        value.reviewToolUpdates([selected])
        XCTAssertEqual(value.bulkInstallableCount, 1)
        value.updateToolPackage = { item, _ in
            XCTAssertEqual(item.package.name, "alpha")
            return .init(source: .npm, installed: ["alpha":"2", "beta":"1"], updates: [.init(name: "beta", installed: "1", available: "2")])
        }
        value.startAllUpdates(); await value.bulkTask?.value
        XCTAssertEqual(value.visibleToolUpdates.map { $0.package.name }, ["beta"])
        XCTAssertFalse(value.bulkSummaryVisible, "Single-package success must return to the remaining updates")
        value.reviewAllUpdates()
        XCTAssertEqual(value.bulkInstallableCount, 1, "An enabled but current source is not an upgrade task")
    }
    func testOldSourceHistoryStillDecodesWithoutPackageAndIdentityIncludesEnvironment() throws {
        let (_, preferences) = try store()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode([ToolUpdateRecord(source: .npm)])) as! [[String: Any]]
        json[0].removeValue(forKey: "item")
        preferences.set(try JSONSerialization.data(withJSONObject: json), forKey: "toolHistoryV1")
        XCTAssertNil(AppStore(preferences: preferences).toolHistory.first?.item)
        let package = ToolPackage(name: "same", installed: "1", available: "2")
        XCTAssertNotEqual(ToolUpdateItem(source: .npm, package: package).id, ToolUpdateItem(source: .pnpm, package: package).id)
        XCTAssertNotEqual(ToolUpdateItem(source: .npm, package: package, context: "/a").id, ToolUpdateItem(source: .npm, package: package, context: "/b").id)
    }

}
