import XCTest
import AppKit
import SwiftUI
import UpoviCore
@testable import Upovi

@MainActor
final class TransferProgressTests: XCTestCase {
    func testFrequentCallbacksDoNotInflateRatesAndConcurrentRatesAddUp() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-rate-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        preferences.set(false, forKey: GlobalP2PSettings.key)
        let store = AppStore(preferences: preferences)
        let start = Date(timeIntervalSince1970: 10_000)
        store.beginTransfer("a", at: start)
        store.beginTransfer("b", at: start)
        // Four callbacks are suppressed before each publication. None may count a byte twice.
        for step in 1...10 {
            let now = start.addingTimeInterval(Double(step) / 10)
            store.reportDownload("a", received: Int64(step) * 100_000, expected: 10_000_000, at: now)
            store.reportDownload("b", received: Int64(step) * 200_000, expected: 20_000_000, at: now)
        }
        let now = start.addingTimeInterval(1)
        let a = try XCTUnwrap(store.transfers["a"]), b = try XCTUnwrap(store.transfers["b"])
        XCTAssertEqual(a.liveBytesPerSecond(at: now), 1_000_000, accuracy: 1)
        XCTAssertEqual(b.liveBytesPerSecond(at: now), 2_000_000, accuracy: 1)
        XCTAssertEqual([a, b].reduce(0) { $0 + $1.liveBytesPerSecond(at: now) }, 3_000_000, accuracy: 1)
        XCTAssertEqual(a.received, 1_000_000)
        XCTAssertEqual(a.fraction, 0.08, accuracy: 0.001)
        store.setTransferPhase("b", .installing)
        XCTAssertEqual(store.transfers["b"]?.liveBytesPerSecond(at: now), 0)
        XCTAssertEqual(a.liveBytesPerSecond(at: now.addingTimeInterval(2)), 0)
        // A retry gets a new baseline rather than inheriting the old transfer's sample.
        store.beginTransfer("a", at: now)
        store.reportDownload("a", received: 250_000, expected: 10_000_000, at: now.addingTimeInterval(0.5))
        XCTAssertEqual(store.transfers["a"]?.bytesPerSecond, 500_000)
    }

    func testCompletionRemovesDownloadRateAndRestartDoesNotProduceANegativeRate() {
        let now = Date(timeIntervalSince1970: 10_000)
        var sample = TransferProgress.Sample(startedAt: now)
        XCTAssertTrue(sample.record(1_000_000, at: now.addingTimeInterval(1)))
        XCTAssertTrue(sample.record(0, at: now.addingTimeInterval(1.1)))
        XCTAssertEqual(sample.bytesPerSecond, 0)
        XCTAssertTrue(sample.record(250_000, at: now.addingTimeInterval(1.6)))
        XCTAssertEqual(sample.bytesPerSecond, 500_000, accuracy: 1)
        var transfer = TransferProgress(phase: .downloading)
        transfer.bytesPerSecond = 2_000_000; transfer.sampleTime = now
        XCTAssertEqual(transfer.liveBytesPerSecond(at: now), 2_000_000)
        for phase: TransferProgress.Phase in [.queued, .verifying, .awaitingConfirmation, .waitingForAuthorization, .installing, .installed, .failed, .cancelled] {
            transfer.phase = phase
            XCTAssertEqual(transfer.liveBytesPerSecond(at: now), 0)
        }
        XCTAssertFalse(TransferProgress.rate(.infinity).isEmpty)
    }
    func testRowHeightStaysStableAcrossTransferStatesAtNarrowAndWideWidths() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-layout-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        preferences.set(false, forKey: GlobalP2PSettings.key)
        let store = AppStore(preferences: preferences)
        let app = InstalledApp(name: "Download layout fixture", bundleID: "app.synthetic.layout", version: "1",
                               path: "/synthetic/layout.app", teamID: "SYNTHETIC")
        let candidate = UpdateCandidate(version: "2", source: "Fixture", isCommunity: false, url: nil,
            download: .init(url: URL(string: "https://example.invalid/update.zip")!, sha256: String(repeating: "a", count: 64)),
            releaseNotes: "Synthetic release notes")
        let item = BulkUpdateItem(application: app, candidate: candidate, manualReason: nil)
        for width: CGFloat in [680, 920] {
            store.transfers = [:]
            let idle = NSHostingView(rootView: UpdateRow(store: store, item: item).frame(width: width)).fittingSize.height
            XCTAssertGreaterThan(idle, 60)
            XCTAssertLessThan(idle, 100)
            for phase: TransferProgress.Phase in [.queued, .downloading, .verifying, .awaitingConfirmation, .waitingForAuthorization, .installing, .installed, .failed, .cancelled] {
                var progress = TransferProgress(phase: phase)
                progress.received = 42_000_000; progress.expected = 80_000_000
                progress.bytesPerSecond = 2_400_000; progress.sampleTime = Date()
                store.transfers[app.id] = progress
                let height = NSHostingView(rootView: UpdateRow(store: store, item: item).frame(width: width)).fittingSize.height
                XCTAssertEqual(height, idle, accuracy: 0.5, "Row moved at width \(width), phase \(phase)")
            }
            store.transfers = [:]; store.bulkSummaryVisible = false
            let header = NSHostingView(rootView: UpdatesOverview(store: store, total: 4, installable: 4).frame(width: width)).fittingSize.height
            XCTAssertLessThan(header, 110)
            print("Transfer layout width=\(width) rowHeight=\(idle) headerHeight=\(header)")
            store.beginTransfer(app.id)
            let single = NSHostingView(rootView: UpdatesOverview(store: store, total: 4, installable: 4).frame(width: width)).fittingSize.height
            XCTAssertEqual(single, header, accuracy: 0.5)
            store.bulkItems = [item]; store.bulkSummaryVisible = true; store.bulkUpdating = true
            let batch = NSHostingView(rootView: UpdatesOverview(store: store, total: 4, installable: 4).frame(width: width)).fittingSize.height
            XCTAssertEqual(batch, header, accuracy: 0.5)
        }
    }

}
