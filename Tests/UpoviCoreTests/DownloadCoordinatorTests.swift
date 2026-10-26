import XCTest
@testable import UpoviCore

private actor TransferGate {
    var calls = 0
    var release = false
    func begin() { calls += 1 }
    func count() -> Int { calls }
    func finish() { release = true }
    func ready() -> Bool { release }
}
@MainActor final class DownloadCoordinatorTests: XCTestCase {
    private let app = InstalledApp(name: "Fixture", bundleID: "app.synthetic.download", version: "1", path: "/synthetic/Fixture.app", teamID: "SYNTHETIC")
    private let descriptor = DownloadDescriptor(url: URL(string: "https://example.invalid/App.zip?private=SECRET")!, sha256: String(repeating: "a", count: 64))
    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<500 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for the expected download state")
        throw URLError(.timedOut)
    }
    private func destination() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "Upovi-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appending(path: "Output.zip")
    }
    func testPauseSuspendsCallerAndResumeRestartsOnlyTheTransfer() async throws {
        let gate = TransferGate(), destination = try destination()
        let center = DownloadCoordinator { _, _, target, phase, resume, progress in
            await gate.begin(); phase(.downloading); progress(4, 8)
            while !(await gate.ready()) { try await Task.sleep(for: .milliseconds(10)) }
            resume(4); phase(.verifying); try Data("complete".utf8).write(to: target)
        }
        let task = Task { try await center.download(descriptor, app: app, to: destination, progress: { _, _ in }) }
        try await eventually { await gate.count() == 1 }
        let snapshot = await center.snapshot()
        let id = try XCTUnwrap(snapshot.first?.id)
        await center.pause(id)
        try await eventually { await center.snapshot().first?.state == .paused }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        await gate.finish(); await center.resume(id); try await task.value
        let calls = await gate.count(); XCTAssertEqual(calls, 2)
        let completed = await center.snapshot()
        let record = try XCTUnwrap(completed.first)
        XCTAssertEqual(record.state, .verified); XCTAssertEqual(record.received, 8)
    }
    func testNetworkLossWaitsAndReconnectResumesWithoutAnotherCaller() async throws {
        let gate = TransferGate(), destination = try destination()
        let center = DownloadCoordinator { _, _, target, _, _, _ in
            await gate.begin()
            while !(await gate.ready()) { try await Task.sleep(for: .milliseconds(10)) }
            try Data("verified".utf8).write(to: target)
        }
        let task = Task { try await center.download(descriptor, app: app, to: destination, progress: { _, _ in }) }
        try await eventually { await gate.count() == 1 }
        await center.setOnline(false)
        try await eventually { await center.snapshot().first?.state == .waitingForNetwork }
        await gate.finish(); await center.setOnline(true); try await task.value
        let state = await center.snapshot().first?.state; XCTAssertEqual(state, .verified)
    }
    func testCancelAndParentCancellationReleaseAPausedCaller() async throws {
        for parentCancellation in [false, true] {
            let center = DownloadCoordinator { _, _, _, _, _, _ in try await Task.sleep(for: .seconds(30)) }
            let destination = try destination()
            let task = Task { try await center.download(descriptor, app: app, to: destination, progress: { _, _ in }) }
            try await eventually { !(await center.snapshot()).isEmpty }
            let snapshot = await center.snapshot()
        let id = try XCTUnwrap(snapshot.first?.id)
            await center.pause(id)
            if parentCancellation { task.cancel() } else { await center.cancel(id) }
            do { try await task.value; XCTFail("Cancelled transfer completed") } catch { XCTAssertTrue(error is CancellationError) }
            let state = await center.snapshot().first?.state; XCTAssertEqual(state, .cancelled)
        }
    }
    func testTransientFailuresHaveABoundedRetryBudgetAndIntegrityFailuresNeverRetry() async throws {
        for transient in [false, true] {
            let gate = TransferGate(), destination = try destination()
            let center = DownloadCoordinator { _, _, _, _, _, _ in
                await gate.begin()
                if transient { throw URLError(.networkConnectionLost) }
                throw PeerError.invalid("Integrity mismatch")
            }
            do { try await center.download(descriptor, app: app, to: destination, progress: { _, _ in }); XCTFail("Failure accepted") } catch { }
            let calls = await gate.count(), record = await center.snapshot().first
            XCTAssertEqual(calls, transient ? 4 : 1)
            XCTAssertEqual(record?.retries, transient ? 3 : 0)
            XCTAssertEqual(record?.state, .failed)
        }
        XCTAssertFalse(DownloadCoordinator.retryable(URLError(.secureConnectionFailed)))
        XCTAssertFalse(DownloadCoordinator.retryable(HTTPStatusError(statusCode: 403)))
        XCTAssertTrue(DownloadCoordinator.retryable(HTTPStatusError(statusCode: 503)))
    }
    func testRestartMarksActiveHistoryInterruptedWithoutPersistingURLsOrProofs() async throws {
        let destination = try destination(), journal = destination.deletingLastPathComponent().appending(path: "tasks.json")
        let center = DownloadCoordinator(storageURL: journal) { _, _, _, _, _, _ in try await Task.sleep(for: .seconds(30)) }
        let task = Task { try await center.download(descriptor, app: app, targetVersion: "2.0", to: destination, progress: { _, _ in }) }
        try await eventually { await center.snapshot().first?.state == .downloading }
        let restarted = DownloadCoordinator(storageURL: journal) { _, _, _, _, _, _ in XCTFail("Restart must not start a download") }
        let restartedState = await restarted.snapshot().first?.state; XCTAssertEqual(restartedState, .interrupted)
        let text = try String(contentsOf: journal, encoding: .utf8)
        XCTAssertFalse(text.contains("SECRET")); XCTAssertFalse(text.contains("example.invalid")); XCTAssertFalse(text.contains(String(repeating: "a", count: 64)))
        task.cancel(); _ = try? await task.value
        let permissions = try FileManager.default.attributesOfItem(atPath: journal.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testExistingOutputAndCorruptHistoryArePreserved() async throws {
        let destination = try destination(), original = Data("existing".utf8)
        try original.write(to: destination)
        let journal = destination.deletingLastPathComponent().appending(path: "history.json")
        let broken = Data("broken history".utf8); try broken.write(to: journal)
        let center = DownloadCoordinator(storageURL: journal) { _, _, target, _, _, _ in try Data("new".utf8).write(to: target) }
        do { try await center.download(descriptor, app: app, to: destination, progress: { _, _ in }); XCTFail("Existing output was accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        let other = destination.deletingLastPathComponent().appending(path: "New.zip")
        try await center.download(descriptor, app: app, to: other, progress: { _, _ in })
        XCTAssertEqual(try Data(contentsOf: journal), broken)
        let failed = await center.historySaveFailed; XCTAssertTrue(failed)
    }

}
