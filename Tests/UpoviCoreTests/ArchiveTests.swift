import XCTest
@testable import UpoviCore

final class ArchiveTests: XCTestCase {
    private func archive(_ entries: [(String, String, Bool)]) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-archive-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var output = Data(), central = Data()
        func le(_ number: UInt32, _ count: Int) -> Data { Data((0..<count).map { UInt8((number >> ($0 * 8)) & 255) }) }
        for (name, text, symlink) in entries {
            let bytes = Data(text.utf8), path = Data(name.utf8), offset = output.count
            var crc: UInt32 = 0xffffffff
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 != 0 ? 0xedb88320 : 0) }
            }
            crc ^= 0xffffffff
            output += le(0x04034b50, 4) + le(20, 2) + Data(repeating: 0, count: 8) + le(crc, 4)
            output += le(UInt32(bytes.count), 4) + le(UInt32(bytes.count), 4) + le(UInt32(path.count), 2) + le(0, 2) + path + bytes
            central += le(0x02014b50, 4) + le(0x0314, 2) + le(20, 2) + Data(repeating: 0, count: 8) + le(crc, 4)
            central += le(UInt32(bytes.count), 4) + le(UInt32(bytes.count), 4) + le(UInt32(path.count), 2) + Data(repeating: 0, count: 8)
            central += le((symlink ? UInt32(0o120777) : UInt32(0o100644)) << 16, 4) + le(UInt32(offset), 4) + path
        }
        let offset = output.count; output += central
        output += le(0x06054b50, 4) + Data(repeating: 0, count: 4) + le(UInt32(entries.count), 2) + le(UInt32(entries.count), 2)
        output += le(UInt32(central.count), 4) + le(UInt32(offset), 4) + le(0, 2)
        let zip = root.appending(path: "archive.zip"); try output.write(to: zip)
        return (zip, root.appending(path: "Extracted"))
    }
    func testExtractsRegularFilesAndSafeFrameworkSymlinks() throws {
        let (zip, output) = try archive([("App.app/Versions/A/file", "hello", false), ("App.app/Versions/Current", "A", true)])
        try ArchiveExtractor.extractZIP(zip, to: output)
        XCTAssertEqual(try String(contentsOf: output.appending(path: "App.app/Versions/Current/file"), encoding: .utf8), "hello")
    }
    func testRejectsParentTraversal() throws {
        let (zip, output) = try archive([("../outside", "unsafe", false)])
        XCTAssertThrowsError(try ArchiveExtractor.extractZIP(zip, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.deletingLastPathComponent().appending(path: "outside").path))
    }
    func testRejectsWritesThroughSymlinkAndDuplicateMembers() throws {
        for entries: [(String, String, Bool)] in [
            [("App/link", ".", true), ("App/link/file", "unsafe", false)],
            [("App/file", "first", false), ("App/file", "second", false)],
            [("App/link", "../../outside", true)]
        ] {
            let (zip, output) = try archive(entries)
            XCTAssertThrowsError(try ArchiveExtractor.extractZIP(zip, to: output))
        }
    }

    /// Finder and `ditto` archives keep extended attributes, such as code signatures of non-Mach-O
    /// bundle files, in AppleDouble members; both inline and __MACOSX layouts must round-trip.
    func testRestoresAppleDoubleAttributesSoDetachedSignaturesStayValid() throws {
        for sequester in [false, true] {
            let root = FileManager.default.temporaryDirectory.appending(path: "Upovi-appledouble-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root.appending(path: "Source/Fixture.app/Contents/Resources"), withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let resource = root.appending(path: "Source/Fixture.app/Contents/Resources/icon.icns")
            try Data("icon".utf8).write(to: resource)
            try run("/usr/bin/codesign", ["--force", "--sign", "-", resource.path])
            try run("/usr/bin/xattr", ["-w", "com.example.upovi", "kept", resource.path])
            let zip = root.appending(path: "fixture.zip")
            try run("/usr/bin/ditto", ["-c", "-k"] + (sequester ? ["--sequesterRsrc"] : []) + ["--keepParent", root.appending(path: "Source/Fixture.app").path, zip.path])
            let output = root.appending(path: "Extracted")
            try ArchiveExtractor.extractZIP(zip, to: output)
            let extracted = output.appending(path: "Fixture.app/Contents/Resources/icon.icns")
            XCTAssertEqual(getxattr(extracted.path, "com.example.upovi", nil, 0, 0, XATTR_NOFOLLOW), 4, "sequester=\(sequester)")
            XCTAssertGreaterThan(getxattr(extracted.path, "com.apple.cs.CodeDirectory", nil, 0, 0, XATTR_NOFOLLOW), 0)
            try run("/usr/bin/codesign", ["--verify", "--strict", extracted.path])
            // FileManager hides AppleDouble files, so list the directory with find(1).
            let pipe = Pipe(), finder = Process()
            finder.executableURL = URL(fileURLWithPath: "/usr/bin/find"); finder.arguments = [output.path, "-name", "._*", "-o", "-name", "__MACOSX"]
            finder.standardOutput = pipe; try finder.run(); finder.waitUntilExit()
            XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "", "sequester=\(sequester)")
        }
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: tool, code: Int(process.terminationStatus)) }
    }
}
