import Foundation

public struct SourceResult: Sendable {
    public let appID: String
    public let candidates: [UpdateCandidate]
    public let note: String
    public let status: SourceStatus
    public let manualURL: URL?
    public init(appID: String, candidates: [UpdateCandidate], note: String, status: SourceStatus = .current, manualURL: URL? = nil) {
        self.appID = appID; self.candidates = candidates; self.note = note; self.status = status; self.manualURL = manualURL
    }
}

public enum UpdateChecker {
    // Exact bundle identifiers only. A similar display name is not an application identity.
    public static let casks = [
        "com.google.Chrome": "google-chrome", "org.mozilla.firefox": "firefox",
        "com.microsoft.VSCode": "visual-studio-code", "com.microsoft.VSCodeInsiders": "visual-studio-code@insiders",
        "com.sublimetext.4": "sublime-text", "org.videolan.vlc": "vlc",
        "com.colliderli.iina": "iina", "com.googlecode.iterm2": "iterm2",
        "com.tinyspeck.slackmacgap": "slack", "com.spotify.client": "spotify",
        "com.figma.Desktop": "figma", "com.hnc.Discord": "discord", "com.raycast.macos": "raycast",
        "com.1password.1password": "1password", "com.docker.docker": "docker-desktop"
    ]


    public static let githubRepositories = [
        "com.knollsoft.Rectangle": "rxhanson/Rectangle", "eu.exelban.Stats": "exelban/stats",
        "com.caldis.Mos": "Caldis/Mos", "com.colliderli.iina": "iina/iina",
        "com.aone.keka": "aonez/Keka", "com.ranchero.NetNewsWire-Evergreen": "Ranchero-Software/NetNewsWire",
        "com.steipete.codexbar": "steipete/CodexBar", "app.upovi.Upovi": "WillSuo-Github/Upovi",
        "com.stablyai.orca": "stablyai/orca", "com.audiout.Audiout": "aa-hh/Audiout"
    ]

    public static func check(_ app: InstalledApp, override: SourceOverride? = nil) async -> SourceResult {
        if app.isAppStore { return .init(appID: app.id, candidates: [], note: "由 App Store 管理更新", status: .appStore) }
        if override?.appcast == nil, override?.githubRepository == nil, let hint = ManualUpdateSource.forBundle(app.bundleID) {
            return .init(appID: app.id, candidates: [], note: hint.note, status: .unsupported, manualURL: hint.url)
        }
        var candidates: [UpdateCandidate] = [], notes: [String] = []
        var checked = 0, failed = 0, uncomparable = 0
        if let feed = override?.appcast ?? app.feedURL {
            do {
                let data = try await fetch(feed, limit: 3_000_000)
                candidates += try AppcastReader.read(data).filter { candidate in
                    candidate.usesBuildVersion
                        ? !app.build.isEmpty && VersionOrder.compare(candidate.build, app.build) == .orderedDescending
                        : VersionOrder.isNewer(version: candidate.version, build: candidate.build, than: app)
                }
                checked += 1; notes.append("已检查开发者 appcast")
            } catch is CancellationError { return .init(appID: app.id, candidates: [], note: "检测已取消", status: .failed) }
            catch { failed += 1; notes.append("appcast：\(error.localizedDescription)") }
        }
        if Task.isCancelled { return .init(appID: app.id, candidates: [], note: "检测已取消", status: .failed) }
        do {
            let metadata: CaskMetadata?
            if let cask = casks[app.bundleID] {
                metadata = try JSONDecoder().decode(CaskMetadata.self, from: await fetch(URL(string: "https://formulae.brew.sh/api/cask/\(cask).json")!, limit: 2_000_000))
            } else { metadata = try await CaskCatalog.shared.metadata(for: app) }
            if let metadata {
                let pieces = metadata.currentVersion.split(separator: ",", maxSplits: 1).map(String.init)
                let version = SourceVersion.normalize(pieces.first ?? "")
                let declaredBuild = pieces.count > 1 ? pieces[1] : ""
                let build = app.build != app.version && declaredBuild.range(of: #"^\d+(?:\.\d+)*$"#, options: .regularExpression) != nil ? declaredBuild : ""
                let comparable = SourceVersion.comparable(version, installed: app.version)
                let installed = InstalledApp(name: app.name, bundleID: app.bundleID, version: SourceVersion.normalize(app.version),
                                             build: app.build, path: app.path, teamID: app.teamID)
                if comparable && VersionOrder.isNewer(version: version, build: build, than: installed) {
                    candidates.append(.init(version: version, build: build, source: "Homebrew", isCommunity: false,
                        url: URL(string: "https://formulae.brew.sh/cask/\(metadata.token)"), download: metadata.download))
                }
                if comparable { checked += 1; notes.append("已检查 Homebrew") }
                else { uncomparable += 1; notes.append("Homebrew 已找到来源，但版本格式无法可靠比较，请使用官方更新") }
            }
        } catch { failed += 1; notes.append("Homebrew：\(error.localizedDescription)") }
        if let repository = override?.githubRepository ?? githubRepositories[app.bundleID], !Task.isCancelled {
            do {
                let release = try await GitHubRelease.latest(repository: repository)
                if VersionOrder.isNewer(version: release.version, than: app) {
                    candidates.append(.init(version: release.version, source: "GitHub Release", isCommunity: false,
                                            url: release.page, download: release.download, releaseNotes: release.releaseNotes))
                }
                checked += 1; notes.append("已检查 GitHub Release")
            } catch { failed += 1; notes.append("GitHub：\(error.localizedDescription)") }
        }
        let status: SourceStatus = failed > 0 ? (checked > 0 ? .partial : .failed)
            : !candidates.isEmpty ? .updates : checked > 0 ? (uncomparable > 0 ? .partial : .current) : .unsupported
        let hint = ManualUpdateSource.forBundle(app.bundleID)
        return .init(appID: app.id, candidates: candidates, note: notes.isEmpty ? hint?.note ?? "暂未适配更新来源，可手动设置开发者 appcast 或 GitHub 仓库" : notes.joined(separator: " · "), status: status, manualURL: hint?.url)
    }

    public static func fetch(_ url: URL, limit: Int) async throws -> Data {
        try await HTTPTransfer.data(from: url, limit: limit)
    }
}
