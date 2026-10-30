import XCTest
import UpoviCore
@testable import Upovi

@MainActor final class ToolSourceWorkflowTests: XCTestCase {
    private func store() throws -> (AppStore, AppPreferences) {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-tool-workflow-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let preferences = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        preferences.set(false, forKey: GlobalP2PSettings.key)
        let installer = UpdateInstaller(journalDirectory: root.appending(path: "Journal"), downloadCache: ArtifactDownloadCache(directory: root.appending(path: "Cache")))
        let value = AppStore(preferences: preferences, installer: installer, scanApplications: { _ in [] })
        value.administrator = AdministratorInstallationService(directory: root.appending(path: "Attempts"), downloads: installer.downloads)
        value.toolLocations = [.npm: URL(fileURLWithPath: "/fixture/npm"), .uv: URL(fileURLWithPath: "/fixture/uv")]
        value.checkToolSource = { source, _ in .init(source: source, context: "/fixture/global", installed: ["tool":"1.0"], updates: [.init(name: "tool", installed: "1.0", available: "2.0")]) }
        return (value, preferences)
    }
    func testSourcesDefaultOffAndEnablingOnlyChecksAndPersists() async throws {
        let (value, preferences) = try store()
        XCTAssertTrue(value.enabledToolSources.isEmpty)
        value.updateToolSource = { _, _, _ in XCTFail("A toggle must not update packages"); throw PeerError.invalid("Unexpected write") }
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
        value.updateToolSource = { source, _, _ in .init(source: source, context: "/fixture/global", installed: ["tool":"2.0"], updates: []) }
        value.setToolSource(.npm, enabled: true); await value.toolCheckTask?.value
        value.reviewAllUpdates()
        XCTAssertTrue(value.bulkUpdatePresented); XCTAssertEqual(value.bulkInstallableCount, 1)
        value.startAllUpdates(); await value.bulkTask?.value
        XCTAssertEqual(value.bulkCompletedCount, 1); XCTAssertEqual(value.bulkFailedCount, 0)
        XCTAssertTrue(value.batchHistory.isEmpty)
        XCTAssertEqual(value.toolHistory.first?.state, .succeeded)
        XCTAssertEqual(AppStore(preferences: preferences).toolHistory.first?.state, .succeeded)
        XCTAssertFalse(value.installationBusy)
    }
    func testStoppingFinishesCurrentSourceAndDoesNotStartTheNext() async throws {
        let (value, _) = try store()
        value.setToolSource(.npm, enabled: true); await value.toolCheckTask?.value
        value.setToolSource(.uv, enabled: true); await value.toolCheckTask?.value
        value.updateToolSource = { [weak value] source, _, _ in
            XCTAssertEqual(source, .npm)
            await value?.stopAllUpdates()
            return .init(source: source, installed: ["tool":"2.0"], updates: [])
        }
        value.reviewAllUpdates(); value.startAllUpdates(); await value.bulkTask?.value
        XCTAssertEqual(value.bulkCompletedCount, 1)
        XCTAssertEqual(value.toolOutcomes[.uv]?.state, .interrupted)
        XCTAssertEqual(value.toolHistory.count, 1)
    }
    func testInterruptedToolHistoryNeverAutomaticallyResumes() throws {
        let (_, preferences) = try store()
        preferences.set(try JSONEncoder().encode([ToolUpdateRecord(source: .npm)]), forKey: "toolHistoryV1")
        let value = AppStore(preferences: preferences)
        XCTAssertEqual(value.toolHistory.first?.state, .interrupted)
        XCTAssertFalse(value.bulkUpdating); XCTAssertNil(value.bulkTask)
    }
}
