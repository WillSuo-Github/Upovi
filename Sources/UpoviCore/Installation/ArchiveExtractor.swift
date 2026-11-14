import Foundation
import ArchiveSupport

public enum ArchiveExtractor {
    public static func extractZIP(_ source: URL, to destination: URL) throws {
        try extractZIP(source, to: destination, recovery: false)
    }
    static func extractRecoveryZIP(_ source: URL, to destination: URL) throws {
        try extractZIP(source, to: destination, recovery: true)
    }
    private static func extractZIP(_ source: URL, to destination: URL, recovery: Bool) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        var message = [CChar](repeating: 0, count: 512)
        let extractor = recovery ? upovi_extract_recovery_zip : upovi_extract_zip
        guard extractor(source.path, destination.path, &message, message.count, { Task.isCancelled ? 1 : 0 }) == 0 else {
            throw PeerError.invalid(String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
    }
}
