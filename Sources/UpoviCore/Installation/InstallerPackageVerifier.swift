import Foundation

public enum InstallerPackageVerifier {
    public static func signerTeam(in output: String) -> String? {
        let pattern = #"(?m)^\s*1\. Developer ID Installer: [^\r\n]+\(([A-Z0-9]{10})\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[range])
    }
    public static func validate(_ package: URL, sha256: String, app: InstalledApp) async throws {
        try BundleVerifier.verifyArchive(package, descriptor: .init(url: package, sha256: sha256), app: app)
        let output = try await ProcessCommand().run("/usr/sbin/pkgutil", ["--check-signature", package.path])
        guard let team = signerTeam(in: String(decoding: output, as: UTF8.self)), team == app.teamID else {
            throw PeerError.invalid("Installer package developer does not match the installed application")
        }
        _ = try await ProcessCommand().run("/usr/sbin/spctl", ["--assess", "--type", "install", package.path])
    }
}
