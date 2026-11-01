import Foundation

public struct InstallationSpaceError: LocalizedError, Sendable {
    public let required: Int64
    public let available: Int64
    public init(required: Int64, available: Int64) { self.required = required; self.available = available }
    public var errorDescription: String? {
        "Insufficient free space for protected backup and package expansion (required=\(required), available=\(available))"
    }
    public var userMessage: String {
        let needed = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
        let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
        return String(localized: "磁盘空间不足：至少需要 \(needed)，目前可用 \(free)。请释放空间后重试。")
    }
}

/// Shared conservative policy: preflight before downloading/authorization, then recheck in the root helper.
public enum AdministratorInstallationSpace {
    public static func requiredBytes(applicationBytes: Int64) -> Int64 {
        let size = max(0, applicationBytes)
        let (doubled, overflow) = size.multipliedReportingOverflow(by: 2)
        let (total, sumOverflow) = doubled.addingReportingOverflow(4_000_000_000)
        return overflow || sumOverflow ? Int64.max : max(6_000_000_000, total)
    }
    public static func check(required: Int64, available: Int64) throws {
        guard available > required else { throw InstallationSpaceError(required: required, available: max(0, available)) }
    }
    public static func validate(application: URL, volumePath: URL? = nil) throws {
        let keys: [URLResourceKey] = [.fileSizeKey, .isSymbolicLinkKey]
        var size: Int64 = 0
        if let iterator = FileManager.default.enumerator(at: application, includingPropertiesForKeys: keys) {
            for case let url as URL in iterator {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
                let (total, overflow) = size.addingReportingOverflow(max(0, Int64(values.fileSize ?? 0)))
                size = overflow ? Int64.max / 4 : min(Int64.max / 4, total)
                if size > 4_000_000_000 { break }
            }
        }
        let storage = volumePath ?? application.deletingLastPathComponent()
        let free = (try FileManager.default.attributesOfFileSystem(forPath: storage.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        try check(required: requiredBytes(applicationBytes: size), available: free)
    }
    public static func message(for error: any Error) -> String? {
        if let space = error as? InstallationSpaceError { return space.userMessage }
        let text = error.localizedDescription
        guard text.contains("Insufficient free space for protected backup and package expansion") else { return nil }
        if let regex = try? NSRegularExpression(pattern: #"required=(\d+), available=(\d+)"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(match.range(at: 1), in: text), let a = Range(match.range(at: 2), in: text),
           let required = Int64(text[r]), let available = Int64(text[a]) {
            return InstallationSpaceError(required: required, available: available).userMessage
        }
        return String(localized: "磁盘空间不足。请先释放安装与备份所需的空间，再重试。")
    }
}
