import Foundation
import ArchiveSupport

public enum ArchiveExtractor {
    public static func extractZIP(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        var message = [CChar](repeating: 0, count: 512)
        guard upovi_extract_zip(source.path, destination.path, &message, message.count, { Task.isCancelled ? 1 : 0 }) == 0 else {
            throw PeerError.invalid(String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
    }
}
