import Foundation

public struct GitHubRelease: Decodable, Sendable {
    let tag_name: String
    let html_url: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    let body: String?
    var rateLimitIssue: DiagnosticIssue? = nil
    private enum CodingKeys: String, CodingKey { case tag_name, html_url, draft, prerelease, assets, body }
    struct Asset: Decodable, Sendable {
        let name: String
        let browser_download_url: URL
        let digest: String?
    }
    public var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    public var page: URL { html_url }
    public var isPrerelease: Bool { prerelease || VersionOrder.isPrerelease(version) }
    public var releaseNotes: String? { body.map { String($0.prefix(20_000)) } }
    public var download: DownloadDescriptor? {
        let compatible = assets.filter { asset in
            let name = asset.name.lowercased()
            guard ["dmg", "zip", "pkg"].contains(asset.browser_download_url.pathExtension.lowercased()),
                  !name.contains("symbols"), !name.contains("source"), !name.contains("windows"), !name.contains("linux") else { return false }
            #if arch(arm64)
            return !name.contains("x86_64") && !name.contains("x64") && !name.contains("intel")
            #else
            return !name.contains("arm64") && !name.contains("aarch64") && !name.contains("apple-silicon")
            #endif
        }
        // Prefer a single DMG; ambiguous assets require the source page instead of guessing.
        let images = compatible.filter { $0.browser_download_url.pathExtension.lowercased() == "dmg" }
        let choices = images.isEmpty ? compatible : images
        guard choices.count == 1, let asset = choices.first, let digest = asset.digest, digest.hasPrefix("sha256:") else { return nil }
        let value = DownloadDescriptor(url: asset.browser_download_url, sha256: String(digest.dropFirst(7)))
        return value.hasIntegrityProof ? value : nil
    }
    public static func validRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.count <= 100 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) } }
            && !parts.contains(".") && !parts.contains("..")
    }
    public static func latest(repository: String, channel: ReleaseChannel = .stable) async throws -> GitHubRelease {
        try await latest(repository: repository, channel: channel, fetch: { try await UpdateChecker.fetch($0, limit: $1) })
    }
    static func latest(repository: String, channel: ReleaseChannel = .stable, fetch: @Sendable (URL, Int) async throws -> Data) async throws -> GitHubRelease {
        guard validRepository(repository) else { throw PeerError.invalid("Invalid GitHub owner/repository") }
        let suffix = channel == .stable ? "/latest" : "?per_page=50"
        let data: Data
        do { data = try await fetch(URL(string: "https://api.github.com/repos/\(repository)/releases\(suffix)")!, 3_000_000) }
        catch let limited as HTTPStatusError where limited.rateLimited && channel == .stable {
            // The public latest-stable page is a separate official version source. Do not retry the
            // throttled API, guess prerelease status from Atom tags, or invent asset hashes.
            do {
                UpoviLog.sources.warning("event=github.publicFallbackRequested \(UpoviDiagnosticContext.errorSummary(limited))")
                var fallback = try publicStable(await fetch(URL(string: "https://github.com/\(repository)/releases/latest")!, 2_000_000), repository: repository)
                UpoviLog.sources.info("event=github.publicFallbackConfirmed version=\(fallback.version) downloadProof=false")
                fallback.rateLimitIssue = DiagnosticIssue(limited)
                return fallback
            } catch { UpoviLog.sources.warning("event=github.publicFallbackRejected \(UpoviDiagnosticContext.errorSummary(error))"); throw limited }
        }
        let releases = channel == .stable ? [try JSONDecoder().decode(Self.self, from: data)] : try JSONDecoder().decode([Self].self, from: data)
        guard releases.count <= 50 else { throw PeerError.invalid("Oversized GitHub release list") }
        let eligible = releases.filter { release in
            !release.draft && (channel == .beta || !release.isPrerelease) &&
                release.page.scheme == "https" && release.page.host == "github.com" &&
                release.page.path.lowercased().hasPrefix("/\(repository.lowercased())/releases/tag/") && VersionOrder.compare(release.version, "0") != nil
        }
        guard let release = eligible.max(by: { VersionOrder.compare($0.version, $1.version) == .orderedAscending }),
              eligible.filter({ VersionOrder.compare($0.version, release.version) == .orderedSame }).count == 1 else {
            throw PeerError.invalid("Invalid stable GitHub release")
        }
        return release
    }
    static func publicStable(_ data: Data, repository: String) throws -> Self {
        guard validRepository(repository), data.count <= 2_000_000, let html = String(data: data, encoding: .utf8),
              let end = html.range(of: "</head>", options: .caseInsensitive), html.distance(from: html.startIndex, to: end.lowerBound) <= 200_000 else {
            throw PeerError.invalid("Invalid GitHub latest-stable page")
        }
        let head = String(html[..<end.lowerBound])
        let regex = try NSRegularExpression(pattern: #"<meta\b(?=[^>]*\bproperty\s*=\s*["']og:url["'])(?=[^>]*\bcontent\s*=\s*["']([^"']+)["'])[^>]*>"#, options: .caseInsensitive)
        let matches = regex.matches(in: head, range: NSRange(head.startIndex..., in: head))
        guard matches.count == 1, let match = matches.first, let range = Range(match.range(at: 1), in: head),
              let url = URL(string: String(head[range]), relativeTo: URL(string: "https://github.com")!)?.absoluteURL,
              url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw PeerError.invalid("Missing GitHub release identity")
        }
        let prefix = "/\(repository)/releases/tag/"
        guard url.path.lowercased().hasPrefix(prefix.lowercased()) else { throw PeerError.invalid("GitHub release belongs to a different repository") }
        let tag = String(url.path.dropFirst(prefix.count))
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard tag.count <= 128, !tag.contains("/"), VersionOrder.compare(version, "0") != nil,
              !VersionOrder.isPrerelease(version) else { throw PeerError.invalid("Unconfirmed stable GitHub version") }
        return .init(tag_name: tag, html_url: url, draft: false, prerelease: false, assets: [], body: nil)
    }

}
