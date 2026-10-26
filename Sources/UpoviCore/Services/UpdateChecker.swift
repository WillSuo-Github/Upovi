import Foundation

public struct SourceResult: Sendable {
    public let appID: String
    public let candidates: [UpdateCandidate]
    public let note: String
    public let status: SourceStatus
    public let manualURL: URL?
    public let checks: [SourceCheckDetail]
    public let appStoreID: UInt64?
    public init(appID: String, candidates: [UpdateCandidate], note: String, status: SourceStatus = .current, manualURL: URL? = nil, checks: [SourceCheckDetail] = [], appStoreID: UInt64? = nil) {
        self.appID = appID; self.candidates = candidates; self.note = note; self.status = status; self.manualURL = manualURL; self.checks = checks; self.appStoreID = appStoreID
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
        "com.willsuo.livehub": "WillSuo-Github/livehub-desktop",
        "io.playcover.PlayCover": "PlayCover/PlayCover",
        "com.stablyai.orca": "stablyai/orca", "com.audiout.Audiout": "aa-hh/Audiout"
    ]

    public static func check(_ app: InstalledApp, override: SourceOverride? = nil) async -> SourceResult {
        if app.isAppStore { return await AppStoreCatalog.shared.check(app) }
        return await check(app, override: override, fetch: { try await fetch($0, limit: $1) }, catalog: { try await CaskCatalog.shared.metadata(for: $0) })
    }

    static func check(_ app: InstalledApp, override: SourceOverride? = nil,
                      fetch: @Sendable (URL, Int) async throws -> Data,
                      catalog: @Sendable (InstalledApp) async throws -> CaskMetadata?) async -> SourceResult {
        if app.isAppStore { return .init(appID: app.id, candidates: [], note: "由 App Store 管理更新", status: .appStore, checks: [.init(.appStore, .manual)]) }
        let browserVersion = app.bundleID == "com.electron.lark" && (Int(app.version.split(separator: ".").first.map(String.init) ?? "") ?? 0) >= 100
        if let hint = ManualUpdateSource.forBundle(app.bundleID), browserVersion || (override?.appcast == nil && override?.githubRepository == nil) {
            return .init(appID: app.id, candidates: [], note: hint.note, status: .unsupported, manualURL: hint.url, checks: [.init(.manual, .manual)])
        }
        var candidates: [UpdateCandidate] = [], notes: [String] = []
        var checked = 0, failed = 0, uncomparable = 0
        var checks: [SourceCheckDetail] = []
        if let feed = override?.appcast ?? app.feedURL {
            do {
                let data = try await fetch(feed, 3_000_000)
                candidates += try AppcastReader.read(data).filter { candidate in
                    candidate.usesBuildVersion
                        ? !app.build.isEmpty && VersionOrder.compare(candidate.build, app.build) == .orderedDescending
                        : VersionOrder.isNewer(version: candidate.version, build: candidate.build, than: app)
                }
                checked += 1; notes.append("已检查开发者 appcast"); checks.append(.init(.appcast, .checked))
            } catch is CancellationError { return .init(appID: app.id, candidates: [], note: "检测已取消", status: .failed, checks: [.init(.appcast, .cancelled, error: CancellationError())]) }
            catch { failed += 1; notes.append("appcast：\(failureDescription(error))"); checks.append(.init(.appcast, .failed, error: error)) }
        }
        if Task.isCancelled { return .init(appID: app.id, candidates: [], note: "检测已取消", status: .failed) }
        do {
            let metadata: CaskMetadata?
            if let cask = casks[app.bundleID] {
                metadata = try JSONDecoder().decode(CaskMetadata.self, from: await fetch(URL(string: "https://formulae.brew.sh/api/cask/\(cask).json")!, 2_000_000))
            } else { metadata = try await catalog(app) }
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
                if comparable { checked += 1; notes.append("已检查 Homebrew"); checks.append(.init(.homebrew, .checked)) }
                else { uncomparable += 1; checks.append(.init(.homebrew, .uncomparable)); notes.append("Homebrew 已找到来源，但版本格式无法可靠比较，请使用官方更新") }
            }
        } catch { failed += 1; notes.append("Homebrew：\(failureDescription(error))"); checks.append(.init(.homebrew, .failed, error: error)) }
        if let repository = override?.githubRepository ?? githubRepositories[app.bundleID], !Task.isCancelled {
            do {
                let release = try await GitHubRelease.latest(repository: repository, fetch: fetch)
                if VersionOrder.isNewer(version: release.version, than: app) {
                    candidates.append(.init(version: release.version, source: "GitHub Release", isCommunity: false,
                                            url: release.page, download: release.download, releaseNotes: release.releaseNotes))
                }
                checked += 1; notes.append("已检查 GitHub Release"); checks.append(.init(.github, .checked))
            } catch { failed += 1; notes.append("GitHub：\(failureDescription(error))"); checks.append(.init(.github, .failed, error: error)) }
        }
        let status: SourceStatus = failed > 0 ? (checked > 0 ? .partial : .failed)
            : !candidates.isEmpty ? .updates : checked > 0 ? (uncomparable > 0 ? .partial : .current) : .unsupported
        let hint = ManualUpdateSource.forBundle(app.bundleID)
        return .init(appID: app.id, candidates: candidates, note: notes.isEmpty ? hint?.note ?? "暂未适配更新来源，可手动设置开发者 appcast 或 GitHub 仓库" : notes.joined(separator: " · "), status: status, manualURL: hint?.url, checks: checks)
    }

    private static func failureDescription(_ error: any Error) -> String {
        guard let http = error as? HTTPStatusError else { return error.localizedDescription }
        if http.rateLimited { return "服务器限制了请求频率，请稍后重试（HTTP \(http.statusCode)）" }
        if http.statusCode == 403 { return "服务器拒绝了请求，未确认是否有更新（HTTP 403）" }
        if http.statusCode == 404 { return "公开更新来源暂不可用，未确认是否有更新（HTTP 404）" }
        return "来源请求失败（HTTP \(http.statusCode)）"
    }

    public static func fetch(_ url: URL, limit: Int) async throws -> Data {
        try await SourceHTTPClient.shared.data(from: url, limit: limit)
    }
}
