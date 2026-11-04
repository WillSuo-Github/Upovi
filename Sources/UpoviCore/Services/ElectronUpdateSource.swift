import Foundation
import Darwin

/// The deliberately bounded scalar/list subset written by electron-builder. Unsupported YAML
/// (anchors, tags, duplicate fields, arbitrary nesting) fails closed instead of being guessed.
struct ElectronYAML {
    let fields: [String: String]
    let files: [[String: String]]
    init(_ data: Data) throws {
        guard data.count <= 3_000_000, let text = String(data: data, encoding: .utf8), !text.contains("\t") else {
            throw PeerError.invalid("Invalid Electron metadata")
        }
        var fields: [String: String] = [:], files: [[String: String]] = [], inFiles = false
        var file: [String: String]?, blockIndent: Int?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .newlines)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed == "---" { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if let blockIndent, indent > blockIndent { continue }
            blockIndent = nil
            if indent == 0 && !trimmed.hasPrefix("- ") {
                if let file { files.append(file) }; file = nil; inFiles = false
            }
            var content = trimmed
            if content.hasPrefix("- ") {
                guard inFiles, files.count < 100 else { throw PeerError.invalid("Unsupported Electron YAML list") }
                if let file { files.append(file) }; file = [:]; content = String(content.dropFirst(2))
            }
            guard let colon = content.firstIndex(of: ":") else { throw PeerError.invalid("Unsupported Electron YAML") }
            let key = String(content[..<colon]), value = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard key.range(of: #"^[A-Za-z][A-Za-z0-9]*$"#, options: .regularExpression) != nil else { throw PeerError.invalid("Invalid Electron field") }
            if key == "files", indent == 0, value.isEmpty {
                guard fields[key] == nil else { throw PeerError.invalid("Duplicate Electron field") }
                fields[key] = ""; inFiles = true; continue
            }
            if value.hasPrefix("|") || value.hasPrefix(">") {
                guard indent == 0, key == "releaseNotes", fields[key] == nil else { throw PeerError.invalid("Unsupported Electron block") }
                fields[key] = ""; blockIndent = indent; continue
            }
            let scalar = try Self.scalar(value)
            if inFiles {
                guard indent > 0, file != nil, file?[key] == nil else { throw PeerError.invalid("Invalid Electron file entry") }
                file?[key] = scalar
            } else {
                guard indent == 0, fields[key] == nil, !value.isEmpty else { throw PeerError.invalid("Unsupported Electron configuration") }
                fields[key] = scalar
            }
        }
        if let file { files.append(file) }
        self.fields = fields; self.files = files
    }
    private static func scalar(_ value: String) throws -> String {
        guard value.count <= 20_000, !value.hasPrefix("!"), !value.hasPrefix("&"), !value.hasPrefix("*"),
              !value.hasPrefix("{"), !value.hasPrefix("[") else { throw PeerError.invalid("Unsupported Electron scalar") }
        if value.hasPrefix("\"") {
            guard let data = value.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) else { throw PeerError.invalid("Invalid quoted Electron field") }
            return decoded
        }
        if value.hasPrefix("'") {
            guard value.count >= 2, value.hasSuffix("'") else { throw PeerError.invalid("Invalid quoted Electron field") }
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value.components(separatedBy: " #").first!.trimmingCharacters(in: .whitespaces)
    }
}

public enum ElectronUpdateSource: Sendable, Equatable {
    case generic(URL)
    case github(String)

    public static func installed(in app: InstalledApp, channel: ReleaseChannel = .stable) throws -> Self? {
        guard !app.isAppStore else { return nil }
        let resources = URL(fileURLWithPath: app.path).appending(path: "Contents/Resources")
        let file = resources.appending(path: "app-update.yml")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let bundle = URL(fileURLWithPath: app.path).resolvingSymlinksInPath().path
        guard resources.resolvingSymlinksInPath().path.hasPrefix(bundle + "/"),
              file.resolvingSymlinksInPath().path.hasPrefix(resources.resolvingSymlinksInPath().path + "/"),
              (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 65536 else { throw PeerError.invalid("Invalid installed Electron configuration") }
        return try configuration(Data(contentsOf: file), channel: channel)
    }
    public static func configuration(_ data: Data, channel: ReleaseChannel = .stable) throws -> Self {
        let info = try ElectronYAML(data).fields
        guard info["private"] != "true", info["requestHeaders"] == nil, info["updateManifestPublicKey"] == nil,
              info["updateManifestPublicKeys"] == nil,
              info["channel"] == nil || info["channel"] == "latest" || (channel == .beta && info["channel"] == "beta") else {
            throw PeerError.unavailable("This Electron channel requires the application's own updater")
        }
        switch info["provider"] {
        case "generic":
            guard let value = info["url"], let url = URL(string: value), secure(url) else { throw PeerError.invalid("Invalid Electron update URL") }
            guard let host = url.host, host != "invalid", !host.hasSuffix(".invalid") else {
                throw PeerError.unavailable("The installed Electron updater has a placeholder address")
            }
            return .generic(url)
        case "github":
            guard let owner = info["owner"], let repo = info["repo"], GitHubRelease.validRepository(owner + "/" + repo),
                  info["host"] == nil || info["host"] == "github.com",
                  info["releaseType"] == nil || info["releaseType"] == "release" || (channel == .beta && info["releaseType"] == "prerelease") else {
                throw PeerError.unavailable("Unsupported Electron GitHub channel")
            }
            return .github(owner + "/" + repo)
        default: throw PeerError.unavailable("Unsupported Electron update provider")
        }
    }
    static func secure(_ url: URL) -> Bool {
        url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }
    func check(_ app: InstalledApp, channel: ReleaseChannel = .stable, fetch: @Sendable (URL, Int) async throws -> Data) async throws -> UpdateCandidate {
        let feed: URL, page: URL, expectedVersion: String?
        var prerelease = false
        switch self {
        case .generic(let base):
            let stableURL = base.appending(path: "latest-mac.yml")
            let stable: UpdateCandidate?
            do { stable = try Self.read(await fetch(stableURL, 3_000_000), feed: stableURL, page: base) }
            catch let error as HTTPStatusError where error.statusCode == 404 && channel == .beta { stable = nil }
            guard channel == .beta else {
                guard let stable else { throw PeerError.unavailable("No stable Electron manifest") }; return stable
            }
            let betaURL = base.appending(path: "beta-mac.yml")
            do {
                let beta = try Self.read(await fetch(betaURL, 3_000_000), feed: betaURL, page: base, channel: .beta)
                guard let stable else { return beta }
                return VersionOrder.compare(beta.version, stable.version) == .orderedDescending ? beta : stable
            } catch let error as HTTPStatusError where error.statusCode == 404 {
                guard let stable else { throw PeerError.unavailable("No Electron channel manifest") }; return stable
            }
        case .github(let repo):
            let release = try await GitHubRelease.latest(repository: repo, channel: channel, fetch: fetch)
            prerelease = release.isPrerelease
            if let issue = release.rateLimitIssue {
                var candidate = UpdateCandidate(version: release.version, source: "Electron · GitHub", isCommunity: false, url: release.page)
                candidate.sourceIssue = issue
                return candidate
            }
            let manifests = release.assets.filter { $0.name.hasSuffix("-mac.yml") }
            let channelName: String = ["alpha", "beta", "preview", "rc"].first { release.version.lowercased().contains("-" + $0) } ?? "beta"
            let preferred = prerelease ? "\(channelName)-mac.yml" : "latest-mac.yml"
            let feeds = manifests.contains(where: { $0.name == preferred }) ? manifests.filter { $0.name == preferred } : manifests.filter { $0.name == "latest-mac.yml" }
            if feeds.isEmpty {
                guard manifests.isEmpty else { throw PeerError.unavailable("Use the application's own Electron channel") }
                // Some Electron releases omit their manifest: the official GitHub release may
                // still provide an independently hashed, unambiguous native archive.
                return .init(version: release.version, source: "Electron · GitHub", isCommunity: false, url: release.page, download: release.download, releaseNotes: release.releaseNotes, releaseChannel: prerelease ? .beta : nil)
            }
            guard feeds.count == 1, let asset = feeds.first, Self.secure(asset.browser_download_url),
                  asset.browser_download_url.host == "github.com", asset.browser_download_url.path.lowercased().hasPrefix("/\(repo.lowercased())/releases/download/") else {
                throw PeerError.invalid("Ambiguous Electron release manifest")
            }
            feed = asset.browser_download_url; page = release.page; expectedVersion = release.version
        }
        return try Self.read(await fetch(feed, 3_000_000), feed: feed, page: page, expectedVersion: expectedVersion, channel: prerelease ? .beta : .stable)
    }
    static func read(_ data: Data, feed: URL, page: URL? = nil, expectedVersion: String? = nil,
                     architecture: String = hostArchitecture, kernelVersion: String = hostKernelVersion, channel: ReleaseChannel = .stable) throws -> UpdateCandidate {
        let yaml = try ElectronYAML(data), info = yaml.fields
        guard let version = info["version"], version.count <= 128,
              version.range(of: #"^\d+(?:\.\d+){1,3}(?:-(?:alpha|beta|preview|rc)[.-]?\d+|-\d+)?(?:\+[A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil,
              channel == .beta || !VersionOrder.isPrerelease(version), VersionOrder.compare(version, "0") != nil,
              expectedVersion.map({ VersionOrder.compare($0, version) == .orderedSame }) ?? true else { throw PeerError.invalid("Invalid stable Electron version") }
        if let minimum = info["minimumSystemVersion"] {
            guard minimum.range(of: #"^\d+(?:\.\d+)*$"#, options: .regularExpression) != nil,
                  VersionOrder.compare(minimum, kernelVersion).map({ $0 != .orderedDescending }) == true else {
                throw PeerError.unavailable("This Electron release requires a newer system")
            }
        }
        if let staging = info["stagingPercentage"] {
            guard let percent = Int(staging), percent == 100 else { throw PeerError.unavailable("This Electron release is staged; check in the application") }
        }
        // A required manifest signing key cannot be silently ignored by this adapter.
        guard info["signature"] == nil, info["signatures"] == nil else { throw PeerError.unavailable("Use the application's signed Electron updater") }
        let files = yaml.files.isEmpty ? [["url": info["path"] ?? "", "sha512": info["sha512"] ?? ""]] : yaml.files
        let compatible = files.compactMap { row -> DownloadDescriptor? in
            guard let path = row["url"], !path.isEmpty, let url = URL(string: path, relativeTo: feed)?.absoluteURL,
                  Self.secure(url), ["zip", "dmg"].contains(url.pathExtension.lowercased()) else { return nil }
            let name = url.lastPathComponent.lowercased()
            guard !name.contains("blockmap"), !name.contains("symbols"), !name.contains("linux"), !name.contains("windows") else { return nil }
            let arm = name.contains("arm64") || name.contains("aarch64") || name.contains("apple-silicon")
            let intel = name.contains("x64") || name.contains("x86_64") || name.contains("intel")
            guard architecture == "arm64" ? !intel : !arm,
                  let sha = row["sha512"], Data(base64Encoded: sha)?.count == 64 else { return nil }
            return .init(url: url, sha512: sha)
        }
        let images = compatible.filter { $0.url.pathExtension.lowercased() == "dmg" }
        let choices = images.isEmpty ? compatible : images
        let download = choices.count == 1 ? choices.first : nil
        return .init(version: version, source: "Electron", isCommunity: false, url: page ?? feed.deletingLastPathComponent(), download: download,
                     releaseNotes: info["releaseNotes"].flatMap { $0.isEmpty ? nil : $0 }, releaseChannel: channel == .beta ? .beta : nil)
    }
    public static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
    public static var hostKernelVersion: String {
        var system = utsname(); uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.release)
        return withUnsafePointer(to: &system.release) { $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) } }
    }
}
