import Foundation

public struct SourceResult: Codable, Sendable {
    public let appID: String
    public let candidates: [UpdateCandidate]
    public let note: String
    public let status: SourceStatus
    public let manualURL: URL?
    public let checks: [SourceCheckDetail]
    public let appStoreID: UInt64?
    public let installedVersion: String?
    public let checkedAt: Date
    public let retainedFrom: Date?
    public init(appID: String, candidates: [UpdateCandidate], note: String, status: SourceStatus = .current, manualURL: URL? = nil, checks: [SourceCheckDetail] = [], appStoreID: UInt64? = nil, installedVersion: String? = nil, checkedAt: Date = Date(), retainedFrom: Date? = nil) {
        self.appID = appID; self.candidates = candidates; self.note = note; self.status = status; self.manualURL = manualURL; self.checks = checks; self.appStoreID = appStoreID
        self.installedVersion = installedVersion; self.checkedAt = checkedAt; self.retainedFrom = retainedFrom
    }
}

public enum UpdateChecker {
    // Exact bundle identifiers only. A similar display name is not an application identity.
    public static let casks = ApplicationSourceCatalog.casks
    public static let githubRepositories = ApplicationSourceCatalog.githubRepositories

    public static func check(_ app: InstalledApp, override: SourceOverride? = nil) async -> SourceResult {
        if app.isAppStore { return await AppStoreCatalog.shared.check(app) }
        return await check(app, override: override, fetch: { try await fetch($0, limit: $1) }, catalog: { try await CaskCatalog.shared.metadata(for: $0) })
    }

    static func check(_ app: InstalledApp, override: SourceOverride? = nil,
                      fetch: @Sendable (URL, Int) async throws -> Data,
                      catalog: @Sendable (InstalledApp) async throws -> CaskMetadata?, steamRoot: URL? = nil) async -> SourceResult {
        let operation = UpoviLogOperation("source.check", category: .sources,
            details: UpoviDiagnosticContext.application(app) + " customFeed=\(override?.appcast != nil) customRepository=\(override?.githubRepository != nil) selectedChannel=\(override?.releaseChannel?.rawValue ?? "stable")")
        return await UpoviDiagnosticContext.$operationID.withValue(operation.id) {
            let result = await evaluate(app, override: override, fetch: fetch, catalog: catalog, steamRoot: steamRoot)
            operation.finish(result.status.rawValue, details: UpoviDiagnosticContext.sourceResult(result), level: [.failed, .partial].contains(result.status) ? .warning : .info)
            return result
        }
    }

    private static func evaluate(_ app: InstalledApp, override: SourceOverride?,
                      fetch: @Sendable (URL, Int) async throws -> Data,
                      catalog: @Sendable (InstalledApp) async throws -> CaskMetadata?, steamRoot: URL?) async -> SourceResult {
        if app.bundleID == "com.valvesoftware.steam", !app.isAppStore {
            return await SteamUpdateSource.check(app, root: steamRoot ?? SteamUpdateSource.defaultRoot, channel: override?.releaseChannel ?? .stable, fetch: fetch)
        }
        if app.isAppStore { return .init(appID: app.id, candidates: [], note: String(localized: "由 App Store 管理更新"), status: .appStore, checks: [.init(.appStore, .manual)]) }
        let browserVersion = app.bundleID == "com.electron.lark" && (Int(app.version.split(separator: ".").first.map(String.init) ?? "") ?? 0) >= 100
        if let hint = ManualUpdateSource.forBundle(app.bundleID), browserVersion || (override?.appcast == nil && override?.githubRepository == nil) {
            return .init(appID: app.id, candidates: [], note: hint.note, status: .unsupported, manualURL: hint.url, checks: [.init(.manual, .manual)])
        }
        var candidates: [UpdateCandidate] = [], notes: [String] = []
        let channel = override?.releaseChannel ?? .stable
        var checked = 0, failed = 0, uncomparable = 0
        var checks: [SourceCheckDetail] = []
        var electronRepository: String?, electronNeedsOwnUpdater = false
        // Versions the app's own updater currently offers; nil when that channel is unknown or unreadable.
        var officialOffers: [UpdateCandidate]?
        if let feed = override?.appcast ?? app.feedURL ?? ApplicationSourceCatalog.officialFeed(for: app) {
            do {
                let data = try await fetch(feed, 3_000_000)
                let offers = try AppcastReader.read(data, channel: channel)
                officialOffers = offers
                candidates += offers.filter { $0.isNewer(than: app) }
                checked += 1; notes.append(String(localized: "已检查开发者 appcast")); checks.append(.init(.appcast, .checked))
            } catch is CancellationError { return .init(appID: app.id, candidates: [], note: String(localized: "检测已取消"), status: .failed, checks: [.init(.appcast, .cancelled, error: CancellationError())]) }
            catch { failed += 1; notes.append("appcast：\(failureDescription(error))"); checks.append(.init(.appcast, .failed, error: error)) }
        }
        if Task.isCancelled { return .init(appID: app.id, candidates: [], note: String(localized: "检测已取消"), status: .failed) }
        if officialOffers == nil, override?.appcast == nil, override?.githubRepository == nil, !ReviewedSourceCatalog.replacesBrokenElectron(for: app) {
            do {
                if let electron = try ElectronUpdateSource.installed(in: app, channel: channel) {
                    if case .github(let repository) = electron { electronRepository = repository }
                    let offer = try await electron.check(app, channel: channel, fetch: fetch)
                    officialOffers = [offer]
                    if offer.isNewer(than: app) { candidates.append(offer) }
                    if let issue = offer.sourceIssue {
                        failed += 1; checked += 1
                        notes.append(String(localized: "GitHub API 暂时限流；已由官方最新稳定版页面确认版本，下载信息仍待核对。") + retryDescription(issue.retryAt))
                        checks.append(.init(.electron, .failed, issue: issue)); checks.append(.init(.githubPage, .checked))
                    } else {
                        checked += 1; notes.append(String(localized: "已检查 Electron 更新源")); checks.append(.init(.electron, .checked))
                    }
                }
            } catch is CancellationError {
                return .init(appID: app.id, candidates: [], note: String(localized: "检测已取消"), status: .failed, checks: [.init(.electron, .cancelled, error: CancellationError())])
            } catch {
                if case PeerError.unavailable = error {
                    electronNeedsOwnUpdater = true
                    notes.append(String(localized: "此 Electron 更新渠道需在应用内确认（特殊渠道、分批发布、系统要求或来源签名限制）。"))
                    checks.append(.init(.electron, .manual))
                } else {
                    failed += 1; notes.append("Electron：\(failureDescription(error))"); checks.append(.init(.electron, .failed, error: error))
                }
            }
        }
        let appcastCount = candidates.count
        do {
            let metadata: CaskMetadata?
            if let cask = casks[app.bundleID] ?? ApplicationSourceCatalog.catalogExceptions[app.bundleID] {
                let value = try JSONDecoder().decode(CaskMetadata.self, from: await fetch(URL(string: "https://formulae.brew.sh/api/cask/\(cask).json")!, 2_000_000))
                guard value.token == cask, value.disabled != true else { throw PeerError.invalid("Homebrew source identity is unavailable or mismatched") }
                metadata = value
            } else { metadata = try await catalog(app) }
            if let metadata {
                let pieces = metadata.currentVersion.split(separator: ",", maxSplits: 1).map(String.init)
                let sourceVersion = SourceVersion.normalize(pieces.first ?? "")
                let download = metadata.download(for: app)
                let identity = ApplicationSourceCatalog.bundleRelease(for: app, sourceVersion: sourceVersion, download: download?.url)
                let declaredBuild = pieces.count > 1 ? pieces[1] : ""
                let numericBuild = declaredBuild.range(of: #"^\d+(?:\.\d+)*$"#, options: .regularExpression) != nil
                // Some casks declare "short,full" while the signed app uses full for both version keys.
                let fullVersion = app.version == app.build && numericBuild && declaredBuild.hasPrefix(sourceVersion + ".") ? declaredBuild : nil
                let version = identity?.version ?? fullVersion ?? sourceVersion
                let sourceBuild = (app.build != app.version || fullVersion != nil) && numericBuild ? declaredBuild : ""
                let build = identity?.build ?? sourceBuild
                let comparable = SourceVersion.comparable(version, installed: app.version)
                let installed = InstalledApp(name: app.name, bundleID: app.bundleID, version: SourceVersion.normalize(app.version),
                                             build: app.build, path: app.path, teamID: app.teamID)
                if comparable && (channel == .beta || !VersionOrder.isPrerelease(version)) &&
                    VersionOrder.isNewer(version: version, build: build, than: installed, allowPrerelease: channel == .beta) {
                    candidates.append(.init(version: version, build: build, source: "Homebrew", isCommunity: false,
                        url: URL(string: "https://formulae.brew.sh/cask/\(metadata.token)"), download: download,
                        releaseNotes: identity == nil ? nil : String(localized: "来源发布版本：\(sourceVersion)；主应用版本：\(version)（\(build)）。"),
                        releaseChannel: VersionOrder.isPrerelease(version) ? .beta : nil))
                }
                if comparable { checked += 1; notes.append(String(localized: "已检查 Homebrew")); checks.append(.init(.homebrew, .checked)) }
                else { uncomparable += 1; checks.append(.init(.homebrew, .uncomparable)); notes.append(String(localized: "Homebrew 已找到来源，但版本格式无法可靠比较，请使用官方更新")) }
            }
        } catch { failed += 1; notes.append("Homebrew：\(failureDescription(error))"); checks.append(.init(.homebrew, .failed, error: error)) }
        let needsSupplement = supplementDownloads(candidates, for: app).contains { $0.download?.canVerify(for: app) != true }
        if let repository = override?.githubRepository ?? githubRepositories[app.bundleID], repository != electronRepository,
           officialOffers == nil || needsSupplement, !Task.isCancelled {
            do {
                let release = try await GitHubRelease.latest(repository: repository, channel: channel, fetch: fetch)
                if VersionOrder.isNewer(version: release.version, than: app, allowPrerelease: channel == .beta) {
                    candidates.append(.init(version: release.version, source: "GitHub Release", isCommunity: false,
                                            url: release.page, download: release.download, releaseNotes: release.releaseNotes,
                                            releaseChannel: release.isPrerelease ? .beta : nil))
                }
                if let issue = release.rateLimitIssue {
                    failed += 1; checked += 1
                    notes.append(String(localized: "GitHub API 暂时限流；已由官方最新稳定版页面确认版本，下载信息仍待核对。") + retryDescription(issue.retryAt))
                    checks.append(.init(.github, .failed, issue: issue)); checks.append(.init(.githubPage, .checked))
                } else {
                    checked += 1; notes.append(String(localized: "已检查 GitHub Release")); checks.append(.init(.github, .checked))
                }
            } catch { failed += 1; notes.append("GitHub：\(failureDescription(error))"); checks.append(.init(.github, .failed, error: error)) }
        }
        if electronNeedsOwnUpdater {
            return .init(appID: app.id, candidates: [], note: notes.joined(separator: " · "), status: .unsupported, checks: checks)
        }
        if let officialOffers {
            candidates = Array(candidates.prefix(appcastCount)) + candidates.dropFirst(appcastCount).filter { candidate in
                offered(candidate, by: officialOffers) && !officialOffers.contains { offer in
                    offer.buildIsAuthoritative == true && !offer.usesBuildVersion &&
                        VersionOrder.compare(offer.version, candidate.version) == .orderedSame && !offer.isNewer(than: app)
                }
            }
        }
        candidates = supplementDownloads(candidates.filter { channel.permits($0) }, for: app)
        let status: SourceStatus = failed > 0 ? (checked > 0 ? .partial : .failed)
            : !candidates.isEmpty ? .updates : checked > 0 ? (uncomparable > 0 ? .partial : .current) : .unsupported
        let hint = ManualUpdateSource.forBundle(app.bundleID)
        return .init(appID: app.id, candidates: candidates, note: notes.isEmpty ? hint?.note ?? String(localized: "暂未适配更新来源，可手动设置开发者 appcast 或 GitHub 仓库") : notes.joined(separator: " · "), status: status, manualURL: hint?.url, checks: checks)
    }

    /// A built-in updater is authoritative: another source may not get ahead of the newest version the
    /// app's own feed offers (staged rollouts, held or withdrawn releases). Build-only feeds cannot be compared.
    static func offered(_ candidate: UpdateCandidate, by offers: [UpdateCandidate]) -> Bool {
        let versioned = offers.filter { !$0.usesBuildVersion && !$0.version.isEmpty }
        guard !candidate.usesBuildVersion, !versioned.isEmpty else { return true }
        return versioned.contains { VersionOrder.compare($0.version, candidate.version).map { $0 != .orderedAscending } ?? false }
    }

    /// Preserve the source's target/build. A second source may fill a missing download for that version;
    /// the installer still checks the downloaded bundle against the original target, including its build.
    static func supplementDownloads(_ candidates: [UpdateCandidate], for app: InstalledApp) -> [UpdateCandidate] {
        // An older Sparkle/DSA-only installation cannot verify an Ed25519 enclosure.
        // Choose a separately proven matching artifact before downloading, never after a failed signature.
        let hasEdKey: Bool = {
            guard candidates.contains(where: { $0.download?.edSignature != nil }),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: app.path).appending(path: "Contents/Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let encoded = info["SUPublicEDKey"] as? String, let key = Data(base64Encoded: encoded), key.count == 32 else { return false }
            return true
        }()
        func usable(_ descriptor: DownloadDescriptor?) -> Bool {
            guard let descriptor, descriptor.edSignature == nil || hasEdKey else { return false }
            return descriptor.canVerify(for: app)
        }
        return candidates.map { candidate in
            guard !candidate.isCommunity else { return candidate }
            var result = candidate
            if candidate.download?.edSignature != nil, !hasEdKey { result.download = nil }
            guard result.download == nil, !candidate.usesBuildVersion else { return result }
            let matches = candidates.filter {
                !$0.isCommunity && !$0.usesBuildVersion && usable($0.download) &&
                    VersionOrder.compare($0.version, candidate.version) == .orderedSame &&
                    ($0.build.isEmpty || $0.build == candidate.build)
            }
            // Prefer independent archive proof. Ambiguous download URLs remain manual.
            let proven = matches.filter { $0.download?.hasIntegrityProof == true }
            let choices = proven.isEmpty ? matches : proven
            guard Set(choices.compactMap(\.download)).count == 1, let download = choices.first?.download else { return result }
            result.download = download
            return result
        }
    }

    private static func failureDescription(_ error: any Error) -> String {
        guard let http = error as? HTTPStatusError else { return error.localizedDescription }
        if http.rateLimited { return String(localized: "服务器限制了请求频率，请稍后重试（HTTP \(http.statusCode)）") + retryDescription(http.retryAt) }
        if http.statusCode == 403 { return String(localized: "服务器拒绝了请求，未确认是否有更新（HTTP 403）") }
        if http.statusCode == 404 { return String(localized: "公开更新来源暂不可用，未确认是否有更新（HTTP 404）") }
        return String(localized: "来源请求失败（HTTP \(http.statusCode)）")
    }

    static func retryDescription(_ date: Date?) -> String {
        guard let date else { return "" }
        return String(localized: " 可在 \(date.formatted(date: .omitted, time: .standard)) 后重试。")
    }

    public static func fetch(_ url: URL, limit: Int) async throws -> Data {
        try await SourceHTTPClient.shared.data(from: url, limit: limit)
    }
}
