import Foundation
import XCTest
@testable import UpoviCore

final class SettingsFileTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path:"Upovi-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return root
    }
    func testFreshReaderRestoresConsentScopeAndBinaryHistory() throws {
        let url = try directory().appending(path:"settings.plist")
        let history = Data([1,2,3,4])
        try SettingsFile(url:url).write(["publicDiscoveryEnabledV2":true,"publicSharingEnabledV2":false,
            "selectedBundles":["app.upovi.synthetic.test"],"checkHistoryV1":history,
            "publicPublisherCacheV2":["topic":["public-key"]],"checkIntervalV1":15])
        let saved = try XCTUnwrap(SettingsFile(url:url).read())
        XCTAssertEqual(saved["publicDiscoveryEnabledV2"] as? Bool,true)
        XCTAssertEqual(saved["publicSharingEnabledV2"] as? Bool,false)
        XCTAssertEqual(saved["selectedBundles"] as? [String],["app.upovi.synthetic.test"])
        XCTAssertEqual(saved["checkHistoryV1"] as? Data,history)
        XCTAssertEqual(saved["publicPublisherCacheV2"] as? [String:[String]],["topic":["public-key"]])
        XCTAssertEqual(saved["checkIntervalV1"] as? Int,15)
        let mode = try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue,0o600)
    }
    func testInvalidReplacementPreservesLastSavedSettings() throws {
        let url = try directory().appending(path:"settings.plist")
        let storage = SettingsFile(url:url)
        try storage.write(["publicSharingEnabledV2":false])
        let original = try Data(contentsOf:url)
        XCTAssertThrowsError(try storage.write(["unsupported":URL(string:"https://example.com")!]))
        XCTAssertEqual(try Data(contentsOf:url),original)
        XCTAssertThrowsError(try storage.write(["oversize":Data(repeating:0,count:4_000_001)]))
        XCTAssertEqual(try Data(contentsOf:url),original)
    }
    func testMissingCorruptAndOversizedFilesAreDistinct() throws {
        let url = try directory().appending(path:"settings.plist")
        let storage = SettingsFile(url:url)
        XCTAssertNil(try storage.read())
        try Data("corrupt".utf8).write(to:url)
        XCTAssertThrowsError(try storage.read())
        XCTAssertEqual(try Data(contentsOf:url),Data("corrupt".utf8))
        try Data(repeating:0,count:4_000_001).write(to:url)
        XCTAssertThrowsError(try storage.read())
    }
    func testLinkedSettingsCannotReadOrOverwriteAnotherFile() throws {
        let root = try directory(), real = root.appending(path:"original.plist"), link = root.appending(path:"link.plist")
        try SettingsFile(url:real).write(["keep":"original"])
        let original = try Data(contentsOf:real)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:real)
        XCTAssertThrowsError(try SettingsFile(url:link).read())
        XCTAssertThrowsError(try SettingsFile(url:link).write(["keep":"changed"]))
        XCTAssertEqual(try Data(contentsOf:real),original)
    }
    func testUnwritableDestinationReportsFailure() throws {
        let root = try directory(), blocker = root.appending(path:"file")
        try Data("occupied".utf8).write(to:blocker)
        XCTAssertThrowsError(try SettingsFile(url:blocker.appending(path:"settings.plist")).write(["enabled":true]))
        XCTAssertEqual(try Data(contentsOf:blocker),Data("occupied".utf8))
    }
}
