import Foundation

public struct GitHubRelease: Decodable, Sendable {
    let tag_name: String
    let html_url: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    struct Asset: Decodable, Sendable {
        let name: String
        let browser_download_url: URL
        let digest: String?
    }
    public var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    public var page: URL { html_url }
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
    public static func latest(repository: String) async throws -> GitHubRelease {
        guard validRepository(repository) else { throw PeerError.invalid("Invalid GitHub owner/repository") }
        let data = try await UpdateChecker.fetch(URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!, limit: 3_000_000)
        let release = try JSONDecoder().decode(Self.self, from: data)
        guard !release.draft, !release.prerelease, release.page.scheme == "https", release.page.host == "github.com" else {
            throw PeerError.invalid("Invalid stable GitHub release")
        }
        return release
    }
}
