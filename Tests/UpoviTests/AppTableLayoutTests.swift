import AppKit
import SwiftUI
import XCTest
import UpoviCore
@testable import Upovi

@MainActor final class AppTableLayoutTests: XCTestCase {
    func testScrollingDoesNotChangeDocumentHeightForUnchangedRows() async throws {
        let application = NSApplication.shared
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
        try await Task.sleep(for: .milliseconds(250))
        let table = try XCTUnwrap(findTable(in: host))
        XCTAssertEqual(table.numberOfRows, store.apps.count)
        XCTAssertGreaterThan(table.bounds.width, 500)
        var heights = [table.frame.height]
        for row in [30, 60, 120, 180, 239, 120, 0] {
            table.scrollRowToVisible(row)
            try await Task.sleep(for: .milliseconds(50))
            heights.append(table.frame.height)
        }
        print("Table layout: automatic=\(table.usesAutomaticRowHeights), rowHeight=\(table.rowHeight), documentHeights=\(heights)")
        XCTAssertLessThanOrEqual(try XCTUnwrap(heights.max()) - XCTUnwrap(heights.min()), 1,
                                 "Scrolling an unchanged inventory must not change its document height")

        // A source-result update must refresh the cell without moving the viewport or selection.
        let selectedApp = store.apps[120]
        table.selectRowIndexes(IndexSet(integer: 120), byExtendingSelection: false)
        XCTAssertEqual(store.selection, selectedApp.id)
        XCTAssertTrue(window.firstResponder === table)
        table.scrollRowToVisible(120)
        try await Task.sleep(for: .milliseconds(50))
        let origin = table.visibleRect.origin
        store.sourceResults[selectedApp.id] = .init(appID: selectedApp.id,
            candidates: [.init(version: "2.0", source: "Synthetic", isCommunity: false, url: nil)],
            note: "Synthetic source update", status: .updates)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(table.frame.height, heights[0], accuracy: 1)
        XCTAssertEqual(table.visibleRect.origin.y, origin.y, accuracy: 1)
        XCTAssertEqual(table.selectedRow, 120)
        XCTAssertEqual(table.view(atColumn: 2, row: 120, makeIfNecessary: true)?.accessibilityLabel(), "2.0")

        // Filtering and external selection retain the stable application path as their identity.
        store.search = "Application 12"
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(table.numberOfRows, 11)
        let selectedID = store.visibleApps.indices.contains(table.selectedRow) ? store.visibleApps[table.selectedRow].id : nil
        XCTAssertEqual(selectedID, selectedApp.id)
        store.selection = store.visibleApps[0].id
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(table.selectedRow, 0)
        window.makeFirstResponder(table)
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        table.keyDown(with: down)
        XCTAssertEqual(store.selection, store.visibleApps[1].id)

        let menu = try XCTUnwrap(table.menu)
        menu.delegate?.menuNeedsUpdate?(menu)
        XCTAssertEqual(menu.items.map(\.title), ["在 Finder 中显示", "忽略更新提醒"])
        let ignore = menu.items[1]
        XCTAssertTrue(application.sendAction(try XCTUnwrap(ignore.action), to: ignore.target, from: ignore))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(store.ignored.contains(selectedApp.bundleID))
        menu.delegate?.menuNeedsUpdate?(menu)
        XCTAssertEqual(menu.items[1].title, "恢复更新提醒")

        store.search = ""
        try await Task.sleep(for: .milliseconds(100))
        window.setContentSize(NSSize(width: 600, height: 500))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(table.frame.height, heights[0], accuracy: 1)
        XCTAssertEqual(table.selectedRow, 120)
        table.scrollRowToVisible(239)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(table.frame.height, heights[0], accuracy: 1)
    }

    private func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.findTable(in: $0) }.first
    }
}
