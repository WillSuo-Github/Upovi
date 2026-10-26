import AppKit
import SwiftUI
import XCTest
import UpoviCore
@testable import Upovi

@MainActor final class AppTableLayoutTests: XCTestCase {
    func testScrollingDoesNotChangeDocumentHeightForUnchangedRows() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-table-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = AppPreferences(url: root.appending(path: "settings.plist"), migrateUserDefaults: false)
        preferences.set(false, forKey: GlobalP2PSettings.key)
        let store = AppStore(preferences: preferences, scanApplications: { _ in [] })
        store.apps = (0..<240).map { index in
            InstalledApp(name: "Synthetic Application \(index)", bundleID: "app.synthetic.table.\(index)",
                         version: "1.0", path: "/synthetic/table-\(index).app")
        }
        store.section = .all
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 960, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AppTable(store: store))
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(350))
        let scroll = try XCTUnwrap(findVerticalScroll(in: host))
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertNil(findTable(in: host), "The application list must not use an NSTableView bridge")
        var heights = [document.frame.height]
        for row in [30, 60, 120, 180, 239, 120, 0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(row) * ApplicationTable.rowHeight))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(50))
            heights.append(document.frame.height)
        }
        print("SwiftUI table document heights: \(heights)")
        XCTAssertEqual(heights[0], CGFloat(store.apps.count) * ApplicationTable.rowHeight + 8, accuracy: 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(heights.max()) - XCTUnwrap(heights.min()), 1)

        let selectedApp = store.apps[120]
        store.selection = selectedApp.id
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120 * ApplicationTable.rowHeight))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(100))
        let origin = scroll.contentView.bounds.origin
        store.sourceResults[selectedApp.id] = .init(appID: selectedApp.id,
            candidates: [.init(version: "2.0", source: "Synthetic", isCommunity: false, url: nil)],
            note: "Synthetic source update", status: .updates)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(document.frame.height, heights[0], accuracy: 1)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy: 1)
        XCTAssertEqual(store.selection, selectedApp.id)

        store.search = "Application 12"
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.visibleApps.count, 11)
        XCTAssertEqual(store.selection, selectedApp.id)
        store.search = ""
        try await Task.sleep(for: .milliseconds(100))
        window.setContentSize(NSSize(width: 600, height: 500))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(document.frame.height, heights[0], accuracy: 1)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 239 * ApplicationTable.rowHeight))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(document.frame.height, heights[0], accuracy: 1)
    }

    func testColumnResizingFitsTheWindowAndHonorsBothAdjacentMinimums() {
        for width: CGFloat in [300, 460, 568, 1200] {
            let columns = ApplicationTableColumns().fitted(to: width)
            XCTAssertEqual(columns.totalWidth, max(460, width), accuracy: 0.01)
            for boundary in 0..<3 {
                for translation: CGFloat in [-10000, -20, 20, 10000] {
                    let resized = columns.resizingBoundary(boundary, by: translation)
                    XCTAssertEqual(resized.totalWidth, columns.totalWidth, accuracy: 0.01)
                    for (index, minimum) in [200.0, 80, 80, 100].enumerated() {
                        XCTAssertGreaterThanOrEqual(resized.widths[index], minimum)
                    }
                    XCTAssertLessThanOrEqual(resized.widths[1], 160)
                    XCTAssertLessThanOrEqual(resized.widths[2], 160)
                    XCTAssertLessThanOrEqual(resized.widths[3], 180)
                }
            }
        }
    }

    private func findVerticalScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.hasVerticalScroller { return scroll }
        return view.subviews.lazy.compactMap { self.findVerticalScroll(in: $0) }.first
    }

    private func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.findTable(in: $0) }.first
    }
}
