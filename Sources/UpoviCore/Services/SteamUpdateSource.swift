import Darwin
import Foundation

/// Steam's bundle version belongs to its bootstrapper, not the downloaded client.
/// Detection is read-only; installation always stays with Steam's own updater.
public enum SteamUpdateSource {
    public static let manifestURL = URL(string: "https://client-update.steamstatic.com/steam_client_osx")!
    public static let page = URL(string: "https://store.steampowered.com/about/")!
    static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Steam") }

    static func check(_ app: InstalledApp, root: URL = defaultRoot, channel: ReleaseChannel = .stable,
                      fetch: @Sendable (URL, Int) async throws -> Data) async -> SourceResult {
        let installed: String
        do {
            guard channel == .stable else { throw PeerError.unavailable("Steam beta detection requires its own updater") }
            installed = try installedVersion(root: root)
        } catch {
            UpoviLog.sources.warning("event=steam.clientEvidenceUnconfirmed \(UpoviDiagnosticContext.errorSummary(error))")
            return .init(appID: app.id, candidates: [], note: String(localized: "无法可靠读取 Steam 的实际客户端版本或当前渠道。应用包的 6.1 是引导器版本，不能据此判断是否最新；请在 Steam 内检查客户端更新。"),
                status: .unsupported, manualURL: page, checks: [.init(.steam, .manual)])
        }
        do {
            let remote = try version(in: await fetch(manifestURL, 1_000_000))
            let newer = VersionOrder.compare(remote, installed) == .orderedDescending
            UpoviLog.sources.info("event=steam.clientCompared installed=\(installed) official=\(remote) newer=\(newer)")
            let candidate = UpdateCandidate(version: remote, source: "Steam", isCommunity: false, url: page,
                releaseNotes: String(localized: "本机 Steam 客户端构建为 \(installed)，官方清单构建为 \(remote)。应用包版本属于引导器；请在 Steam 内检查并安装客户端更新。"))
            return .init(appID: app.id, candidates: newer ? [candidate] : [],
                note: String(localized: "已核对 Steam 官方客户端清单；本机客户端构建 \(installed)，官方构建 \(remote)。更新须在 Steam 内完成。"),
                status: newer ? .updates : .current, manualURL: page, checks: [.init(.steam, .checked)], installedVersion: installed)
        } catch {
            return .init(appID: app.id, candidates: [], note: String(localized: "Steam 官方客户端清单检查失败，未确认是否有更新：\(error.localizedDescription)"),
                status: .failed, manualURL: page, checks: [.init(.steam, .failed, error: error)], installedVersion: installed)
        }
    }

    static func version(in data: Data) throws -> String {
        guard data.count <= 1_000_000, let text = String(data: data, encoding: .utf8),
              !text.contains("<!"), text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("}"), let root = text.range(of: #"^\s*"osx"\s*\{"#, options: .regularExpression) else {
            throw PeerError.invalid("Invalid Steam client manifest")
        }
        // Only root scalars before the first package object can identify the release.
        let prefix = String(text[root.upperBound...].prefix(while: { $0 != "{" }))
        let expression = try NSRegularExpression(pattern: #"(?m)^\s*"version"\s+"([0-9]{10})"\s*$"#)
        let matches = expression.matches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix))
        guard matches.count == 1, let match = matches.first, let range = Range(match.range(at: 1), in: prefix),
              validBuild(String(prefix[range])) else { throw PeerError.invalid("Missing or ambiguous Steam client build") }
        return String(prefix[range])
    }

    static func installedVersion(root: URL) throws -> String {
        let package = root.appending(path: "Steam.AppBundle/Steam/Contents/MacOS/package")
        let betaFile = package.appending(path: "beta")
        var betaInfo = stat()
        if lstat(betaFile.path, &betaInfo) == 0 {
            let beta = try read(betaFile, within: root, maximum: 128)
            guard String(decoding: beta, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PeerError.unavailable("Steam uses a non-stable client channel")
            }
        } else if errno != ENOENT { throw PeerError.unavailable("Cannot determine Steam client channel") }
        // Downloaded manifests alone can describe a pending update. Require an actual client launch
        // record, a matching installed-file list and manifest, and an unchanged client binary.
        let log = String(decoding: try read(root.appending(path: "logs/console_log.txt"), within: root, maximum: 1_000_000, tail: true), as: UTF8.self)
        let regex = try NSRegularExpression(pattern: #"(?m)^\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\] Client version: ([0-9]{10})\s*$"#)
        guard let record = regex.matches(in: log, range: NSRange(log.startIndex..., in: log)).last,
              let dateRange = Range(record.range(at: 1), in: log), let buildRange = Range(record.range(at: 2), in: log) else {
            throw PeerError.unavailable("Steam has no client launch version record")
        }
        let build = String(log[buildRange])
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"; formatter.timeZone = .current; formatter.isLenient = false
        guard validBuild(build), let launched = formatter.date(from: String(log[dateRange])), launched <= Date().addingTimeInterval(300) else {
            throw PeerError.invalid("Invalid Steam client launch record")
        }
        let binary = root.appending(path: "Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib")
        let binaryPath = try CanonicalFilePath.resolve(binary), rootPath = try CanonicalFilePath.resolve(root)
        guard binaryPath.hasPrefix(rootPath + "/"),
              let modified = try binary.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              modified <= launched else { throw PeerError.unavailable("Steam client changed after its recorded launch") }
        for name in ["steam_client_signed-2_osx", "steam_client_signed_osx", "steam_client_osx"] {
            guard let manifest = try? read(package.appending(path: name + ".manifest"), within: root, maximum: 1_000_000),
                  (try? version(in: manifest)) == build,
                  let installed = try? read(package.appending(path: name + ".installed"), within: root, maximum: 2_000_000), !installed.isEmpty else { continue }
            return build
        }
        throw PeerError.unavailable("Steam's downloaded metadata does not corroborate its installed client")
    }

    private static func validBuild(_ value: String) -> Bool {
        value.utf8.count == 10 && value.allSatisfy(\.isNumber) && UInt64(value).map { (1_000_000_000...4_294_967_295).contains($0) } == true
    }
    private static func read(_ file: URL, within root: URL, maximum: Int, tail: Bool = false) throws -> Data {
        guard try CanonicalFilePath.resolve(file).hasPrefix(CanonicalFilePath.resolve(root) + "/") else { throw PeerError.invalid("Linked Steam metadata outside its data directory") }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
              tail || info.st_size <= maximum else { throw PeerError.invalid("Invalid or oversized Steam metadata") }
        if tail, info.st_size > maximum { try handle.seek(toOffset: UInt64(info.st_size - Int64(maximum))) }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw PeerError.invalid("Oversized Steam metadata") }
        return data
    }
}
