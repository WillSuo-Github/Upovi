import Foundation
import Security
import CryptoKit

public enum BundleVerifier {
    public static func validate(_ url: URL, replacing app: InstalledApp, expectedVersion: String, expectedBuild: String) throws -> InstalledApp {
        guard let incoming = AppScanner.read(url), incoming.bundleID == app.bundleID,
              let team = app.teamID, !team.isEmpty, incoming.teamID == team,
              !incoming.isAppStore, !app.isAppStore else { throw PeerError.invalid("Application identity or developer Team ID mismatch") }
        try checkSignature(url, like: app)
        let info = (try? Data(contentsOf: url.appending(path: "Contents/Info.plist"))).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            guard VersionOrder.compare(minimum, "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") != .orderedDescending else {
                throw PeerError.invalid("Update requires a newer macOS version")
            }
        }
        guard VersionOrder.compare(incoming.version, expectedVersion) == .orderedSame ||
                (expectedVersion == incoming.build && expectedBuild == incoming.build),
              expectedBuild.isEmpty || incoming.build == expectedBuild,
              VersionOrder.isNewer(version: incoming.version, build: incoming.build, than: app) else {
            throw PeerError.invalid("Downloaded application version does not match the selected update")
        }
        return incoming
    }
    public static func checkSignature(_ url: URL, like app: InstalledApp) throws {
        guard let metadata = AppScanner.read(url), metadata.bundleID == app.bundleID,
              let team = app.teamID, metadata.teamID == team else { throw PeerError.invalid("Backup signature identity mismatch") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess else {
            throw PeerError.invalid("Application code signature is invalid")
        }
    }
    public static func verifyArchive(_ archive: URL, descriptor: DownloadDescriptor, app: InstalledApp) throws {
        guard descriptor.hasIntegrityProof else { throw PeerError.invalid("Missing archive integrity proof") }
        if let sha = descriptor.sha256 {
            let input = try FileHandle(forReadingFrom: archive); defer { try? input.close() }
            var hash = SHA256()
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty { try Task.checkCancellation(); hash.update(data: chunk) }
            let value = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard value.caseInsensitiveCompare(sha) == .orderedSame else { throw PeerError.invalid("Downloaded archive checksum mismatch") }
        }
        if let signature = descriptor.edSignature {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: app.path).appending(path: "Contents/Info.plist")),
                  let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let encoded = plist["SUPublicEDKey"] as? String, let raw = Data(base64Encoded: encoded),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
                  key.isValidSignature(signature, for: try Data(contentsOf: archive, options: .mappedIfSafe)) else {
                throw PeerError.invalid("Sparkle archive signature could not be verified against the installed application")
            }
        }
    }
}
